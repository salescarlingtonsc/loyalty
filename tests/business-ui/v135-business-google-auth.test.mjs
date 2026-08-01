import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  const to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

function memorySessionStorage(entries = {}) {
  const values = new Map(Object.entries(entries));
  return {
    getItem(key) { return values.has(key) ? values.get(key) : null; },
    setItem(key, value) { values.set(key, String(value)); },
    removeItem(key) { values.delete(key); },
    has(key) { return values.has(key); },
  };
}

test('business Google OAuth uses the canonical Peekaa callback and no role metadata', () => {
  const oauth = section('function businessOAuthRedirectUrl()', 'function renderBusinessApplication()');
  assert.match(oauth, /NestlyNativeBridge\.publicUrl\('\/business'\)/);
  assert.match(oauth, /searchParams\.set\('oauth','business'\)/);
  assert.match(oauth, /sb\.auth\.signInWithOAuth\(\{\s*provider:'google'/);
  assert.match(oauth, /redirectTo:businessOAuthRedirectUrl\(\)/);
  assert.match(oauth, /scopes:'openid email profile'/);
  assert.match(oauth, /beginBusinessGoogleOAuthAttempt\(\{legalAccepted\}\)/);
  assert.match(oauth, /if\(!ensureCanonicalBusinessOAuthOrigin\(\)\)return/);
  assert.match(oauth, /location\.origin===canonical\.origin/);
  assert.match(oauth, /location\.replace\(canonical\.toString\(\)\)/);
  assert.match(oauth, /catch\{\}/);
  assert.match(oauth, /button\.disabled=false/);
  assert.doesNotMatch(oauth, /role|staff|owner_user_id|app_metadata/);
});

test('business sign-in and owner signup expose one accessible Google action', () => {
  const signup = section('function renderBusinessApplication(){', 'async function renderApprovedBusinessInviteSignup(');
  const signIn = section("function renderAuth(mode='in'", 'function validNewPassword(');
  const button = section('function businessGoogleButtonHtml(id)', 'async function startBusinessGoogleAuth(');
  assert.match(button, />Continue with Google</);
  assert.match(button, /min-height:44px/);
  assert.match(signup, /businessGoogleButtonHtml\('businessApplicationGoogle'\)/);
  assert.match(signup, /id="applicationConsent"/);
  assert.match(signup, /if\(!\$\('applicationConsent'\)\.checked\)/);
  assert.ok(signup.indexOf('id="applicationConsent"') < signup.indexOf("businessGoogleButtonHtml('businessApplicationGoogle')"));
  assert.match(signup, /startBusinessGoogleAuth\(/);
  assert.match(signIn, /businessGoogleButtonHtml\('businessGoogleSignIn'\)/);
  assert.match(signIn, /!admin&&!NestlyNativeBridge\.isNative/);
  assert.match(signIn, /id="businessGoogleLegal"/);
  assert.match(signIn, /If Google creates a new Peekaa account/);
  assert.match(signIn, /if\(!\$\('businessGoogleLegal'\)\.checked\)/);
  assert.match(signIn, /legalAccepted:true/);
  assert.match(signIn, /startBusinessGoogleAuth\(/);
  assert.doesNotMatch(signIn, /Super admin sign in[\s\S]*id="businessGoogleSignIn"[^?]*admin\?/);
});

test('OAuth callback is consumed once before hash routing and recovers visibly', () => {
  const callback = section('async function consumeBusinessOAuthRedirect()', 'async function consumePasswordRecoveryRedirect()');
  assert.match(callback, /search\.get\('oauth'\)!=='business'/);
  assert.match(callback, /hash\.get\('access_token'\)/);
  assert.match(callback, /hash\.get\('refresh_token'\)/);
  assert.match(callback, /const validPendingAttempt=takeBusinessGoogleOAuthAttempt\(\)/);
  assert.match(callback, /if\(!validPendingAttempt\|\|providerError\)/);
  assert.match(app, /attempt\?\.returnPath==='\/business'/);
  assert.match(app, /age<=30\*60\*1000/);
  assert.match(app, /sessionStorage\.removeItem\(key\)/);
  assert.match(callback, /await sb\.auth\.setSession\(\{access_token:oauthAccessToken,refresh_token:oauthRefreshToken\}\)/);
  assert.match(callback, /history\.replaceState\(null,'','\/business'\)/);
  assert.match(callback, /sessionStorage\.setItem\('nestly-business-oauth-notice'/);
  assert.match(callback, /Could not complete Google sign-in/);
  assert.match(app, /await consumeBusinessOAuthRedirect\(\)/);
  assert.ok(app.indexOf('await consumeBusinessOAuthRedirect()') < app.indexOf('await consumePasswordRecoveryRedirect()'));
});

test('pending OAuth attempt is same-tab, recent, shape-valid and single-use', () => {
  const helpers = section('function beginBusinessGoogleOAuthAttempt(', 'async function startBusinessGoogleAuth(');
  const sessionStorage = memorySessionStorage();
  const context = { sessionStorage, Date, Number, JSON };
  vm.createContext(context);
  vm.runInContext(helpers, context);

  assert.equal(context.beginBusinessGoogleOAuthAttempt(), false, 'legal acceptance is mandatory');
  assert.equal(context.beginBusinessGoogleOAuthAttempt({legalAccepted:true}), true);
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), true);
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false, 'a consumed marker cannot replay');

  sessionStorage.setItem('nestly-business-google-oauth', '{bad json');
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false);
  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now()-31*60*1000,returnPath:'/business',legalAccepted:true}));
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false);
  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now()+1000,returnPath:'/business',legalAccepted:true}));
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false);
  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now(),returnPath:'/admin',legalAccepted:true}));
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false);
  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now(),returnPath:'/business',legalAccepted:false}));
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false);
  assert.equal(sessionStorage.has('nestly-business-google-oauth'), false);
});

test('unsolicited, expired and replayed callback tokens never establish a session', async () => {
  const helpers = section('function beginBusinessGoogleOAuthAttempt(', 'async function startBusinessGoogleAuth(');
  const callback = section('async function consumeBusinessOAuthRedirect(){', 'async function consumePasswordRecoveryRedirect()');
  const sessionStorage = memorySessionStorage();
  const calls = { setSession: 0, signOut: 0, scrub: 0 };
  const context = {
    sessionStorage, Date, Number, JSON, URLSearchParams,
    location: { search: '?oauth=business', hash: '#access_token=access&refresh_token=refresh' },
    history: { replaceState() { calls.scrub += 1; } },
    sb: { auth: {
      async setSession() { calls.setSession += 1; return { error: null }; },
      async signOut() { calls.signOut += 1; },
    } },
  };
  vm.createContext(context);
  vm.runInContext(`${helpers}\n${callback}`, context);

  await context.consumeBusinessOAuthRedirect();
  assert.equal(calls.setSession, 0, 'unsolicited tokens are rejected');
  assert.equal(calls.scrub, 1, 'credentials are scrubbed even when rejected');

  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now()-31*60*1000,returnPath:'/business',legalAccepted:true}));
  await context.consumeBusinessOAuthRedirect();
  assert.equal(calls.setSession, 0, 'expired attempts are rejected');

  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now(),returnPath:'/business',legalAccepted:true}));
  await context.consumeBusinessOAuthRedirect();
  assert.equal(calls.setSession, 1, 'one valid pending attempt establishes one session');
  await context.consumeBusinessOAuthRedirect();
  assert.equal(calls.setSession, 1, 'the same callback cannot replay after marker consumption');
});

test('OAuth startup rejection restores the button and visible fallback', async () => {
  const start = section('async function startBusinessGoogleAuth(', 'function renderBusinessApplication(){');
  for (const failure of ['returned', 'thrown']) {
    const sessionStorage = memorySessionStorage();
    const errorHost = { innerHTML: '' };
    const button = { disabled: false };
    const context = {
      sessionStorage,
      beginBusinessGoogleOAuthAttempt() {
        sessionStorage.setItem('nestly-business-google-oauth', '{}');
        return true;
      },
      businessOAuthRedirectUrl() { return 'https://www.peekaa.asia/business?oauth=business'; },
      ensureCanonicalBusinessOAuthOrigin() { return true; },
      $(id) { assert.equal(id, 'autherr'); return errorHost; },
      sb: { auth: { async signInWithOAuth() {
        if (failure === 'thrown') throw new Error('network');
        return { error: new Error('provider') };
      } } },
    };
    vm.createContext(context);
    vm.runInContext(start, context);
    await context.startBusinessGoogleAuth({ button, errorHostId: 'autherr', legalAccepted: true });
    assert.equal(button.disabled, false);
    assert.match(errorHost.innerHTML, /Google sign-in could not be started/);
    assert.equal(sessionStorage.has('nestly-business-google-oauth'), false);
  }
});

test('Google startup canonicalizes before creating an origin-scoped marker', async () => {
  const start = section('async function startBusinessGoogleAuth(', 'function renderBusinessApplication(){');
  const sessionStorage = memorySessionStorage();
  let replaced = '', signInCalls = 0;
  const legacyLocation = { origin: 'https://www.nestly.asia', replace(value) { replaced = value; } };
  const canonicalBridge = { publicUrl(path) { return `https://www.peekaa.asia${path}`; } };
  const context = {
    sessionStorage, URL,
    location: legacyLocation,
    NestlyNativeBridge: canonicalBridge,
    ensureCanonicalBusinessOAuthOrigin() {
      const canonical = new URL(canonicalBridge.publicUrl('/business'));
      if (legacyLocation.origin === canonical.origin) return true;
      legacyLocation.replace(canonical.toString());
      return false;
    },
    beginBusinessGoogleOAuthAttempt() { sessionStorage.setItem('nestly-business-google-oauth', '{}'); return true; },
    businessOAuthRedirectUrl() { return 'https://www.peekaa.asia/business?oauth=business'; },
    $() { return { innerHTML: '' }; },
    sb: { auth: { async signInWithOAuth() { signInCalls += 1; return { error: null }; } } },
  };
  vm.createContext(context);
  vm.runInContext(start, context);
  await context.startBusinessGoogleAuth({ button: { disabled: false }, errorHostId: 'autherr', legalAccepted: true });
  assert.equal(replaced, 'https://www.peekaa.asia/business');
  assert.equal(signInCalls, 0);
  assert.equal(sessionStorage.has('nestly-business-google-oauth'), false);
});

test('a new Google identity initiated from sign-in cannot bypass legal consent', () => {
  const signIn = section("function renderAuth(mode='in'", 'function validNewPassword(');
  assert.match(signIn, /id="businessGoogleLegal" type="checkbox"/);
  assert.ok(signIn.indexOf('id="businessGoogleLegal"') < signIn.indexOf("businessGoogleButtonHtml('businessGoogleSignIn')"));
  assert.match(signIn, /Please accept the Terms and Privacy Policy before continuing with Google/);
  assert.match(signIn, /startBusinessGoogleAuth\(\{button:event\.currentTarget,errorHostId:'autherr',legalAccepted:true\}\)/);
  assert.match(app, /p_legal_accepted:true/);
  assert.match(app, /if\(!\$\('onboardLegalConsent'\)\.checked\)/);
});
