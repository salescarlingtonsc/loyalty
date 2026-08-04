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
  assert.match(oauth, /beginBusinessGoogleOAuthAttempt\(\{intent,legalAccepted\}\)/);
  assert.match(oauth, /if\(!ensureCanonicalBusinessOAuthOrigin\(\)\)return/);
  assert.match(oauth, /location\.origin===canonical\.origin/);
  assert.match(oauth, /location\.replace\(canonical\.toString\(\)\)/);
  assert.match(oauth, /catch\{\}/);
  assert.match(oauth, /button\.disabled=false/);
  assert.doesNotMatch(oauth, /role|staff|owner_user_id|app_metadata/);
});

test('business sign-in and owner signup expose one accessible Google action with consent only at signup', () => {
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
  assert.doesNotMatch(signIn, /id="businessGoogleLegal"/);
  assert.doesNotMatch(signIn, /If Google creates a new Peekaa account/);
  assert.doesNotMatch(signIn, /Please accept the Terms and Privacy Policy before continuing with Google/);
  assert.match(signIn, /startBusinessGoogleAuth\(\{button:event\.currentTarget,errorHostId:'autherr',intent:'signin'\}\)/);
  assert.doesNotMatch(signIn, /Super admin sign in[\s\S]*id="businessGoogleSignIn"[^?]*admin\?/);
});

test('OAuth callback is consumed once before hash routing and recovers visibly', () => {
  const callback = section('async function consumeBusinessOAuthRedirect()', 'async function consumePasswordRecoveryRedirect()');
  assert.match(callback, /search\.get\('oauth'\)!=='business'/);
  assert.match(callback, /hash\.get\('access_token'\)/);
  assert.match(callback, /hash\.get\('refresh_token'\)/);
  assert.match(callback, /const pendingAttempt=takeBusinessGoogleOAuthAttempt\(\)/);
  assert.match(callback, /if\(!pendingAttempt\|\|providerError\)/);
  assert.match(app, /attempt\?\.returnPath==='\/business'/);
  assert.match(app, /age<=30\*60\*1000/);
  assert.match(app, /sessionStorage\.removeItem\(key\)/);
  assert.match(callback, /const admissionClient=createBusinessOAuthAdmissionClient\(\)/);
  assert.match(callback, /await admissionClient\.auth\.setSession\(\{access_token:oauthAccessToken,refresh_token:oauthRefreshToken\}\)/);
  assert.match(callback, /admissionClient\.rpc\('complete_business_google_oauth_v138'/);
  assert.match(callback, /await sb\.auth\.setSession\(\{access_token:oauthAccessToken,refresh_token:oauthRefreshToken\}\)/);
  assert.ok(callback.indexOf("admissionClient.rpc('complete_business_google_oauth_v138'") < callback.indexOf('await sb.auth.setSession('), 'persistent session must follow server admission');
  const oauth = section('function businessOAuthRedirectUrl()', 'function renderBusinessApplication()');
  assert.match(oauth, /storageKey:'nestly-business-oauth-admission-v138',persistSession:false/);
  assert.match(oauth, /autoRefreshToken:false,detectSessionInUrl:false/);
  assert.match(callback, /p_intent:pendingAttempt\.intent,p_attempt_token:pendingAttempt\.attemptToken/);
  assert.match(callback, /history\.replaceState\(null,'','\/business'\)/);
  assert.match(callback, /sessionStorage\.setItem\('nestly-business-oauth-notice'/);
  assert.match(callback, /Could not complete Google sign-in/);
  assert.match(app, /await consumeBusinessOAuthRedirect\(\)/);
  assert.ok(app.indexOf('await consumeBusinessOAuthRedirect()') < app.indexOf('await consumePasswordRecoveryRedirect()'));
});

test('pending OAuth attempt distinguishes sign-in from server-recorded consented signup and remains single-use', async () => {
  const legal = section('const BUSINESS_LEGAL_V138=', 'function businessGoogleButtonHtml(');
  const helpers = section('async function beginBusinessGoogleOAuthAttempt(', 'async function startBusinessGoogleAuth(');
  const sessionStorage = memorySessionStorage();
  const tokens=['11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222'];
  const rpcCalls=[];
  const context = { sessionStorage, Date, Number, JSON,
    crypto:{randomUUID:()=>tokens.shift()},
    sb:{rpc:async(name,args)=>{rpcCalls.push({name,args});return {data:{accepted:true},error:null}}}
  };
  vm.createContext(context);
  vm.runInContext(`${legal}\n${helpers}`, context);

  assert.equal(await context.beginBusinessGoogleOAuthAttempt({intent:'signin'}), true, 'ordinary sign-in has no consent checkbox');
  assert.deepEqual({...context.takeBusinessGoogleOAuthAttempt()},{intent:'signin',legalAccepted:false,attemptToken:null});
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false, 'a consumed marker cannot replay');

  assert.equal(await context.beginBusinessGoogleOAuthAttempt({intent:'signup'}), false, 'signup still requires legal acceptance');
  assert.equal(await context.beginBusinessGoogleOAuthAttempt({intent:'signup',legalAccepted:true}), true);
  assert.deepEqual({...context.takeBusinessGoogleOAuthAttempt()},{
    intent:'signup',legalAccepted:true,attemptToken:'11111111-1111-4111-8111-111111111111'
  });
  assert.equal(rpcCalls.length,1);
  assert.equal(rpcCalls[0].name,'begin_business_google_oauth_signup_v138');
  assert.equal(rpcCalls[0].args.p_terms_version,'2026-08-04');
  assert.equal(rpcCalls[0].args.p_terms_sha256,'012e09a4a7b6df2a5acc9da3b6512c1cfeb42e903fd8306f6ff09866a9f1e4a5');
  assert.equal(rpcCalls[0].args.p_privacy_sha256,'8e152d208b271da5a1f71630b17c5c82e8b7bd930c5508da8b4d95597c0a1568');

  sessionStorage.setItem('nestly-business-google-oauth', '{bad json');
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false);
  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now()-31*60*1000,returnPath:'/business',intent:'signin',legalAccepted:false}));
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false);
  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now()+1000,returnPath:'/business',intent:'signin',legalAccepted:false}));
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false);
  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now(),returnPath:'/admin',intent:'signin',legalAccepted:false}));
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false);
  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now(),returnPath:'/business',intent:'signup',legalAccepted:false}));
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false);
  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now(),returnPath:'/business',intent:'signup',legalAccepted:true,attemptToken:'forged'}));
  assert.equal(context.takeBusinessGoogleOAuthAttempt(), false);
  assert.equal(sessionStorage.has('nestly-business-google-oauth'), false);
});

test('unsolicited, expired, rejected and replayed callback tokens never retain a session', async () => {
  const helpers = section('function takeBusinessGoogleOAuthAttempt(', 'async function startBusinessGoogleAuth(');
  const callback = section('async function consumeBusinessOAuthRedirect(){', 'async function consumePasswordRecoveryRedirect()');
  const sessionStorage = memorySessionStorage();
  const calls = { transientSetSession: 0, persistentSetSession: 0, signOut: 0, scrub: 0 };
  let rejectAdmission = false;
  const context = {
    sessionStorage, Date, Number, JSON, URLSearchParams,
    location: { search: '?oauth=business', hash: '#access_token=access&refresh_token=refresh' },
    history: { replaceState() { calls.scrub += 1; } },
    sb: { auth: {
      async setSession() { calls.persistentSetSession += 1; return { error: null }; },
      async signOut() { calls.signOut += 1; },
    } },
    createBusinessOAuthAdmissionClient() { return { auth: {
      async setSession() { calls.transientSetSession += 1; return { error: null }; },
    }, async rpc(name,args) {
      assert.equal(name,'complete_business_google_oauth_v138');
      calls.admissionArgs=args;
      return rejectAdmission?{data:null,error:new Error('existing business required')}:{data:{admitted:true},error:null};
    } }; },
  };
  vm.createContext(context);
  vm.runInContext(`${helpers}\n${callback}`, context);

  await context.consumeBusinessOAuthRedirect();
  assert.equal(calls.transientSetSession, 0, 'unsolicited tokens are rejected before token exchange');
  assert.equal(calls.persistentSetSession, 0, 'unsolicited tokens are never persisted');
  assert.equal(calls.scrub, 1, 'credentials are scrubbed even when rejected');

  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now()-31*60*1000,returnPath:'/business',intent:'signin',legalAccepted:false}));
  await context.consumeBusinessOAuthRedirect();
  assert.equal(calls.transientSetSession, 0, 'expired attempts are rejected');
  assert.equal(calls.persistentSetSession, 0, 'expired attempts are never persisted');

  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now(),returnPath:'/business',intent:'signin',legalAccepted:false}));
  await context.consumeBusinessOAuthRedirect();
  assert.equal(calls.transientSetSession, 1, 'one valid pending attempt establishes one memory-only session');
  assert.equal(calls.persistentSetSession, 1, 'the admitted attempt is then persisted once');
  assert.deepEqual({...calls.admissionArgs},{p_intent:'signin',p_attempt_token:null});
  await context.consumeBusinessOAuthRedirect();
  assert.equal(calls.transientSetSession, 1, 'the same callback cannot replay after marker consumption');
  assert.equal(calls.persistentSetSession, 1, 'replay cannot persist again');

  rejectAdmission=true;
  sessionStorage.setItem('nestly-business-google-oauth', JSON.stringify({startedAt:Date.now(),returnPath:'/business',intent:'signin',legalAccepted:false}));
  await context.consumeBusinessOAuthRedirect();
  assert.equal(calls.transientSetSession,2,'rejected login exists only in the transient client');
  assert.equal(calls.persistentSetSession,1,'rejected login never reaches persistent storage');
  assert.equal(calls.signOut,1,'server-rejected new Google login is signed out');
  assert.match(sessionStorage.getItem('nestly-business-oauth-notice'),/No business account was found/);
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
    await context.startBusinessGoogleAuth({ button, errorHostId: 'autherr', intent: 'signin' });
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
  await context.startBusinessGoogleAuth({ button: { disabled: false }, errorHostId: 'autherr', intent: 'signin' });
  assert.equal(replaced, 'https://www.peekaa.asia/business');
  assert.equal(signInCalls, 0);
  assert.equal(sessionStorage.has('nestly-business-google-oauth'), false);
});

test('new Google identity is rejected from sign-in while signup is server-consent gated', () => {
  const signIn = section("function renderAuth(mode='in'", 'function validNewPassword(');
  const oauth = section('function businessOAuthRedirectUrl()', 'function renderBusinessApplication()');
  const callback = section('async function consumeBusinessOAuthRedirect()', 'async function consumePasswordRecoveryRedirect()');
  assert.doesNotMatch(signIn, /id="businessGoogleLegal"/);
  assert.match(signIn, /startBusinessGoogleAuth\(\{button:event\.currentTarget,errorHostId:'autherr',intent:'signin'\}\)/);
  assert.match(oauth, /begin_business_google_oauth_signup_v138/);
  assert.match(oauth, /p_accepted:true/);
  assert.match(callback, /complete_business_google_oauth_v138/);
  assert.match(callback, /No business account was found for that Google login/);
});
