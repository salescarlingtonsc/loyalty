/* nestly_v681 — audit F108.
   The staff-invite "Continue with Google" door used to redirect to /business?staff_invite=CODE
   with no oauth=business marker and no recorded attempt, so consumeBusinessOAuthRedirect() bailed
   on its first line, detectSessionInUrl:false meant supabase-js ignored the fragment too, and the
   invitee landed back on the sign-in card still signed out. tests/business-ui/v158-gap-closure
   only regex-grepped that `redirectTo:staffInviteOAuthRedirectV158(code)` appeared in the source,
   which stayed green throughout. These tests EXECUTE the round trip instead: the real redirect
   URL is built, its query and fragment are fed to the real consumer with the real attempt slot,
   and the session, the admission intent and the surviving invite code are all asserted. */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

function memoryStorage(entries = {}) {
  const values = new Map(Object.entries(entries));
  return {
    getItem(key) { return values.has(key) ? values.get(key) : null; },
    setItem(key, value) { values.set(key, String(value)); },
    removeItem(key) { values.delete(key); },
    has(key) { return values.has(key); },
  };
}

const inviteHelpers = section("const STAFF_INVITE_STORAGE_V151=", 'function staffInvitePreviewMarkupV151(preview){');
const beginHelper = section('async function beginBusinessGoogleOAuthAttempt(', 'function takeBusinessGoogleOAuthAttempt(');
const takeHelper = section('function takeBusinessGoogleOAuthAttempt(', 'async function startBusinessGoogleAuth(');
const callback = section('async function consumeBusinessOAuthRedirect(){', 'async function consumePasswordRecoveryRedirect()');
const inviteScreen = section('function renderStaffInviteAuthV151(', 'function renderBusinessStaffInviteAcceptV151(');

function inviteContext({ location, sessionStorage }) {
  const context = {
    sessionStorage, URL, URLSearchParams, String, JSON, RegExp,
    location,
    NestlyNativeBridge: { publicUrl: (path) => `https://peekaa.asia${path}` },
  };
  vm.createContext(context);
  vm.runInContext(inviteHelpers, context);
  return context;
}

test('the staff-invite Google redirect carries oauth=business so the consumer will run', () => {
  const context = inviteContext({
    location: { origin: 'https://peekaa.asia', search: '', hash: '' },
    sessionStorage: memoryStorage(),
  });
  const redirect = new URL(context.staffInviteOAuthRedirectV158('7fe2-2596'));
  assert.equal(redirect.origin, 'https://peekaa.asia');
  assert.equal(redirect.pathname, '/business');
  assert.equal(redirect.searchParams.get('oauth'), 'business',
    'without oauth=business consumeBusinessOAuthRedirect returns on its first line');
  assert.equal(redirect.searchParams.get('staff_invite'), '7FE22596');
});

test('a non-canonical origin is sent back to the canonical invite link, code intact', () => {
  const replaced = [];
  const context = inviteContext({
    location: {
      origin: 'https://loyalty-pi-seven.vercel.app', search: '', hash: '',
      replace(url) { replaced.push(url); },
    },
    sessionStorage: memoryStorage(),
  });
  assert.equal(context.ensureCanonicalStaffInviteOriginV681('7FE22596'), false);
  assert.equal(replaced.length, 1);
  const sent = new URL(replaced[0]);
  assert.equal(sent.origin, 'https://peekaa.asia');
  assert.equal(sent.searchParams.get('staff_invite'), '7FE22596',
    'the code must ride the URL because sessionStorage does not cross origins');
  const canonical = inviteContext({
    location: { origin: 'https://peekaa.asia', search: '', hash: '', replace() { throw new Error('must not redirect'); } },
    sessionStorage: memoryStorage(),
  });
  assert.equal(canonical.ensureCanonicalStaffInviteOriginV681('7FE22596'), true);
});

test('the invite Google button records a signup attempt and never a bare signInWithOAuth', () => {
  assert.match(inviteScreen, /ensureCanonicalStaffInviteOriginV681\(code\)/);
  assert.match(inviteScreen, /beginBusinessGoogleOAuthAttempt\(\{intent:'signup',legalAccepted:true\}\)/,
    "an invitee has no active staff row, so complete_business_google_oauth_v138's signin branch refuses them");
  assert.match(inviteScreen, /redirectTo:staffInviteOAuthRedirectV158\(code\)/);
  assert.match(inviteScreen, /sessionStorage\.removeItem\('nestly-business-google-oauth'\)/);
  const begin = inviteScreen.indexOf('beginBusinessGoogleOAuthAttempt');
  const oauth = inviteScreen.indexOf('signInWithOAuth');
  assert.ok(begin >= 0 && oauth > begin, 'the attempt slot must be written before the redirect starts');
  assert.match(inviteScreen, /Continuing with Google accepts the Terms and Privacy Policy/,
    'the signup intent records a legal acceptance, so the card must say so');
});

test('a failed Google admission is reported on the invite card instead of vanishing', () => {
  assert.match(inviteScreen, /sessionStorage\.getItem\('nestly-business-oauth-notice'\)/);
  assert.match(inviteScreen, /sessionStorage\.removeItem\('nestly-business-oauth-notice'\)/);
  assert.match(inviteScreen, /staffInviteOAuthNoticeV681\?`<div class="err">/);
});

test('the invite Google round trip establishes a session and keeps the invite code', async () => {
  const sessionStorage = memoryStorage();
  const calls = { transient: 0, persistent: 0, signOut: 0, admissionArgs: null };
  const attemptContext = {
    sessionStorage, crypto, Date, JSON,
    sb: { rpc: async (name, args) => {
      assert.equal(name, 'begin_business_google_oauth_signup_v138');
      assert.equal(args.p_accepted, true);
      return { data: { accepted: true }, error: null };
    } },
    BUSINESS_LEGAL_V138: { terms: { version: 't', sha256: 'ts' }, privacy: { version: 'p', sha256: 'ps' } },
  };
  vm.createContext(attemptContext);
  vm.runInContext(beginHelper, attemptContext);
  assert.equal(await attemptContext.beginBusinessGoogleOAuthAttempt({ intent: 'signup', legalAccepted: true }), true);

  // The button remembered the code before leaving; the redirect URL is the real one.
  const before = inviteContext({
    location: { origin: 'https://peekaa.asia', search: '', hash: '' },
    sessionStorage,
  });
  before.rememberBusinessStaffInviteV151('7FE22596');
  const redirect = new URL(before.staffInviteOAuthRedirectV158('7FE22596'));

  // Google returns to that URL with the token fragment.
  const location = {
    origin: 'https://peekaa.asia', pathname: redirect.pathname,
    search: redirect.search, hash: '#access_token=access&refresh_token=refresh',
  };
  const consumer = {
    sessionStorage, Date, Number, JSON, URLSearchParams, Error,
    location,
    history: { replaceState(_state, _title, url) { location.pathname = url; location.search = ''; location.hash = ''; } },
    sb: { auth: {
      async setSession() { calls.persistent += 1; return { error: null }; },
      async signOut() { calls.signOut += 1; },
    } },
    createBusinessOAuthAdmissionClient() {
      return {
        auth: { async setSession() { calls.transient += 1; return { error: null }; } },
        async rpc(name, args) {
          assert.equal(name, 'complete_business_google_oauth_v138');
          calls.admissionArgs = args;
          return { data: { admitted: true }, error: null };
        },
      };
    },
  };
  vm.createContext(consumer);
  vm.runInContext(`${takeHelper}\n${callback}`, consumer);
  await consumer.consumeBusinessOAuthRedirect();

  assert.equal(calls.transient, 1, 'the returned tokens reach the memory-only admission client');
  assert.equal(calls.persistent, 1, 'the admitted invite session is persisted — the invitee is signed in');
  assert.equal(calls.signOut, 0);
  assert.equal(calls.admissionArgs.p_intent, 'signup');
  assert.match(calls.admissionArgs.p_attempt_token,
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(sessionStorage.getItem('nestly-business-oauth-notice'), null);

  // The consumer scrubbed the query string; the code must survive in sessionStorage so route()
  // lands on renderBusinessStaffInviteAcceptV151 rather than an empty /business.
  const after = inviteContext({ location: { origin: 'https://peekaa.asia', search: '', hash: '' }, sessionStorage });
  assert.equal(after.businessStaffInviteCodeV151(), '7FE22596');
});
