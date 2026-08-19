import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V289 — audit A3 (customer surface) gap closure.
 *
 * Everything pinned here was a way the customer surface told the person something that was not
 * true, or offered them a control that could not work:
 *   G1 registration completed on the server and then froze, because nav() to the hash already
 *      on screen fires no hashchange and the router listens to nothing else;
 *   G2 a deep link to a business you have not joined said "could not be loaded" and offered a
 *      Retry that could only fail again, while the claim form that could have fixed it was
 *      unreachable code;
 *   G3 every deploy took over live pages (sw install called skipWaiting, activate re-navigated
 *      every window), so a customer could be reloaded mid-OTP;
 *   G4 a paused programme printed a bare "0 points";
 *   G6 four different auth failures shared one sentence, and every retry burned a server-side
 *      rate-limit slot by minting a new idempotency key;
 *   G7 with SMS unavailable the sign-up form still painted every field and a security check that
 *      never finished.
 */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (file) => readFileSync(resolve(repoRoot, file), 'utf8');
const app = read('app/app.js');
const sw = read('app/sw.js');
const pwa = read('app/pwa.js');

const escFn = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const block = (from, to) => {
  const start = app.indexOf(from);
  assert.ok(start > 0, `missing ${from}`);
  const end = app.indexOf(to, start);
  assert.ok(end > start, `missing ${to}`);
  return app.slice(start, end);
};

/* ------------------------------------------------------------------ G1: the nav primitive */

test('G1: nav() to the hash already on screen routes instead of doing nothing', () => {
  const nav = block('function nav(h)', "window.addEventListener('hashchange',route);");
  assert.match(nav, /if\(location\.hash===h\)route\(\);else location\.hash=h/);

  let routed = 0;
  let hash = '#/join';
  const location = { get hash() { return hash; }, set hash(value) { hash = value; } };
  const fn = new Function('location', 'route', `${nav}\nreturn nav;`)(location, () => { routed += 1; });

  fn('#/join');
  assert.equal(routed, 1, 'the destination equal to the current hash must still re-route');
  fn('#/wallet');
  assert.equal(routed, 1, 'a real change still goes through hashchange');
  assert.equal(hash, '#/wallet');
});

test('G1: the post-registration destinations that froze all go through nav()', () => {
  const destination = block('async function resolveCustomerRegistrationDestination', 'function renderCustomerRegistrationProfile');
  /* V289 rebase retarget: main refactored the literal return-token shape while this fixer was
     in flight. The guarantee that matters — every post-registration destination goes through
     nav(), whose same-hash branch now re-routes — is pinned structurally instead. */
  assert.match(destination, /nav\('#\/join'\);/);
  assert.match(destination, /nav\(destination\);/);
  /* A concurrent session fixed the same freeze at the call site with an inline
     `if(location.hash==='#/join')route()` guard — a read, not a write, and a second
     layer of the same guarantee the nav() primitive now carries. Both are kept. */
  assert.doesNotMatch(destination, /location\.hash\s*=[^=]/,
    'destinations must never RAW-ASSIGN the hash and skip the same-hash re-route');
  assert.match(destination, /nav\(takePendingCustomerDestination\('#\/wallet'\)\)/);
});

/* ------------------------------------------- G2: an unjoined business is not a load failure */

test('G2: 42501 on a wallet deep link renders the not-joined state, never Retry', () => {
  const wallet = block('async function renderCustomerWallet(', 'async function renderCustomerInAppInbox');
  /* v333: `silent?undefined:` — a background poll keeps the page the customer is reading. A
     denial on a poll is not new information about a wallet that is already on screen, and the
     not-joined card is still the only answer a real render gives. */
  assert.match(wallet, /if\(walletRpcDenied\(error\)\)return silent\?undefined:renderCustomerNotJoinedV289\(businessSlug\)/);
  assert.match(wallet, /if\(walletRpcDenied\(summaryError\)\|\|walletRpcDenied\(capabilitiesError\)\)return silent\?undefined:renderCustomerNotJoinedV289\(businessSlug\)/);
  assert.match(wallet, /if\(!actionableCard\)return silent\?undefined:renderCustomerNotJoinedV289\(businessSlug\)/);
  assert.match(app, /function walletRpcDenied\(error\)\{return error\?\.code==='42501'\}/,
    'the denial code this rests on must stay 42501');
});

test('G2: the not-joined card says so, carries the intent into claiming, and escapes the slug', () => {
  const source = block('function customerBusinessSlugLabelV289', 'function renderCustomerWalletRetry');
  const label = new Function(`${source}\nreturn customerBusinessSlugLabelV289;`)();
  assert.equal(label('kopi-tiam-east'), 'Kopi Tiam East');
  assert.equal(label(''), 'this business');

  assert.match(source, /You haven’t joined \$\{esc\(label\)\} yet/);
  assert.match(source, /nav\('#\/claim\?business='\+encodeURIComponent/,
    'the slug the link supplied must be carried into the join flow, not discarded');
  assert.match(source, /pendingCustomerBusinessSlug=normalizeCustomerBusinessIntent\(businessSlug\)/);
  assert.doesNotMatch(source, /Retry/, 'a membership that does not exist cannot be retried into existence');
  assert.match(source, /esc\(label\)/, 'the slug comes from the URL and is always escaped');
});

test('G2: the claim form is reachable once a business-issued link names the business', () => {
  const claim = block('async function renderCustomerClaim()', 'function renderCustomerWalletUnavailable');
  assert.match(claim, /if\(!invitationToken&&!businessIntent\)\{/,
    'only a visit with NO carried intent may be sent away to scan a QR');
  // the previously unreachable controls are still there, and still server-backed
  assert.match(claim, /id="claimSlug"/);
  assert.match(claim, /customer_claim_link_by_verified_phone/);
  assert.match(claim, /customer_claim_link_by_email/);
  // discovery stays QR/link only: no search, no directory, no listing on this surface
  assert.doesNotMatch(claim, /search for a business|browse businesses/i);
});

test('G2: a repeated claim keeps one idempotency key per unchanged attempt', () => {
  const claim = block('async function renderCustomerClaim()', 'function renderCustomerWalletUnavailable');
  assert.match(claim, /if\(!claimAttempt\|\|claimAttempt\.key!==attemptKey\)claimAttempt=\{key:attemptKey,id:crypto\.randomUUID\(\)\}/);
});

/* --------------------------------------------------------- G3: deploys stop hijacking pages */

test('G3: the worker waits for consent instead of taking over on install', () => {
  const install = sw.slice(sw.indexOf("self.addEventListener('install'"), sw.indexOf("self.addEventListener('activate'"));
  assert.doesNotMatch(install, /skipWaiting/, 'install must not promote itself over a live page');
  assert.match(sw, /event\.data\?\.type==='SKIP_WAITING'\)self\.skipWaiting\(\)/,
    'the guarded applyUpdate path must still be able to promote the waiting worker');
  /* V321 goes further than V289 could (owner 2026-08-14: "the website still keeps refreshing
     itself. - remove this"). V289 stopped the WORKER promoting itself on install; the PAGE still
     auto-applied the update 1.2s after finding one, whenever it judged the moment safe. Consent
     is now the only trigger — applyUpdate is reachable from the prompt's action and nowhere else. */
  const pwaCode = pwa.replace(/\/\*[\s\S]*?\*\//g,'').replace(/^\s*\/\/.*$/gm,'');
  assert.doesNotMatch(pwaCode, /isUnsafeToAutoUpdate/);
  assert.doesNotMatch(pwaCode, /setTimeout\([^)]*applyUpdate/);
  /* The declaration `function applyUpdate(worker){` matches the bare name too, so exclude it —
     what is being counted is CALL sites. */
  assert.equal((pwaCode.match(/(?<!function\s)applyUpdate\(worker\)/g) || []).length, 1,
    'applyUpdate must have exactly one call site — the "Update now" button');
  assert.match(pwa, /onAction:\(\)=>applyUpdate\(worker\)/);
  assert.match(pwa, /worker\.postMessage\(\{type:'SKIP_WAITING'\}\)/);
});

test('G3: activation notifies open pages but never re-navigates them', () => {
  const activate = sw.slice(sw.indexOf("self.addEventListener('activate'"), sw.indexOf("self.addEventListener('message'"));
  assert.match(activate, /PEEKAA_SW_ACTIVATED/);
  assert.doesNotMatch(activate, /await client\.navigate\(/, 'a tab that consented to nothing must not be reloaded');
  /* V321: V289 narrowed the broadcast's reload to tabs that LOOKED idle. Narrowing was not
     enough — a tab that looks idle still belongs to someone — so the page no longer listens for
     the broadcast at all. The worker may still announce the version; nothing acts on it. */
  assert.doesNotMatch(pwa.replace(/\/\*[\s\S]*?\*\//g,'').replace(/^\s*\/\/.*$/gm,''), /PEEKAA_SW_ACTIVATED/,
    'the activation broadcast must not be a reload path at all, narrowed or otherwise');
  assert.equal((pwa.match(/location\.reload\(\)/g) || []).length, 2,
    'exactly two reloads may exist in pwa.js: the offline Retry button, and the consented update');
  assert.match(pwa, /if\(updateRequested\)globalObject\.location\.reload\(\)/,
    'the one update reload stays gated on the person having asked for it');
});

test('G3: the shell cache is versioned forward and the app document joins it', () => {
  assert.match(sw, /const CACHE_VERSION='v14-20260819-w3-details'/);
  assert.match(sw, /const SHELL_DOCUMENTS=Object\.freeze\(\['\/index\.html','\/app'\]\)/);
  assert.match(sw, /return \(await cache\.match\('\/index\.html'\)\)\|\|\(await cache\.match\('\/offline\.html'\)\)/,
    'offline navigation prefers the real shell and still falls back honestly');
  // navigation targets must not be served by the static-asset branch
  assert.match(sw, /APP_SHELL\.filter\(path=>path!=='\/'&&!SHELL_DOCUMENTS\.includes\(path\)\)/);
});

/* -------------------------------------------------------------- G4: a paused programme says so */

test('G4: enabled:false renders the paused state and never a bare zero', () => {
  const source = block('function customerProgrammePointsPanelV230', 'function customerProgrammeTierPanelV230');
  const panel = new Function('ct', 'esc', 'customerPointTotalV103', 'customerRewardProgressMarkupV167',
    `${source}\nreturn customerProgrammePointsPanelV230;`)(
    (value) => String(value || 'points'), escFn, (value) => String(value ?? 0), () => '');

  const paused = panel({ loyalty: { enabled: false, balance: 0 }, presentation: { unit: null } });
  assert.match(paused, /Programme paused/);
  assert.match(paused, /Anything you already earned is kept/);
  assert.doesNotMatch(paused, /<b>0<\/b>/, 'a zeroed balance from a paused programme is not a balance');

  const running = panel({ loyalty: { enabled: true, balance: 120 }, presentation: { unit: 'points' } });
  assert.match(running, /<b>120<\/b>/);
  const legacy = panel({ loyalty: { balance: 7 }, presentation: { unit: 'points' } });
  assert.match(legacy, /<b>7<\/b>/, 'a payload with no flag keeps the old behaviour');
});

test('G4: the paused wording matches the tier panel it sits beside', () => {
  assert.match(app, /This business is not running a tier programme at the moment\./,
    'the v189 tier wording this mirrors must still exist');
});

/* ------------------------------------------------------- G6: auth failures say what happened */

test('G6: the classifier separates network, rate limit, expired code and bad credentials', () => {
  const source = block('function customerAuthFailureKindV289', 'function customerPasswordUpdateErrorMessage');
  const { kind, message } = new Function('esc', 'globalThis',
    `${source}\nreturn {kind:customerAuthFailureKindV289,message:customerAuthErrorMessageV289};`)(escFn, { navigator: { onLine: true } });

  assert.equal(kind({ name: 'AuthRetryableFetchError', status: 0, message: 'Failed to fetch' }), 'network');
  assert.equal(kind({ status: 429, code: 'over_request_rate_limit' }), 'rate_limited');
  assert.equal(kind({ code: 'otp_expired', message: 'Token has expired or is invalid' }), 'otp_invalid');
  assert.equal(kind({ code: 'invalid_credentials', status: 400 }), 'invalid_credentials');
  assert.equal(kind({ code: 'phone_not_confirmed' }), 'phone_unconfirmed');
  assert.equal(kind({ status: 503 }), 'server');

  assert.match(message({ name: 'AuthRetryableFetchError', status: 0, message: 'Failed to fetch' }, 'sign_in'), /could not reach Peekaa/);
  assert.match(message({ status: 429 }, 'sign_in'), /Wait about a minute/);
  assert.match(message({ status: 429 }, 'otp_send'), /Wait a few minutes/);
  assert.match(message({ code: 'otp_expired' }, 'otp_verify'), /wrong or has expired/);
  assert.match(message({ code: 'invalid_credentials' }, 'sign_in'), /mobile number or password is incorrect/);
});

test('G6: sign-in still refuses to say whether the number is registered', () => {
  const source = block('function customerAuthFailureKindV289', 'function customerPasswordUpdateErrorMessage');
  const message = new Function('esc', 'globalThis', `${source}\nreturn customerAuthErrorMessageV289;`)(escFn, { navigator: { onLine: true } });
  const wrong = message({ code: 'invalid_credentials' }, 'sign_in');
  assert.doesNotMatch(wrong, /no account|not registered|unknown number|does not exist/i,
    'distinguishing an unknown number would make the form an enumeration oracle (PDPA)');
});

test('G6: the three customer auth surfaces use the classifier', () => {
  const signIn = block('function renderCustomerPasswordSignIn', 'async function renderCustomerOtpStart');
  assert.match(signIn, /customerAuthErrorMessageV289\(error,'sign_in'\)/);
  const otp = block('function renderCustomerOtpVerification', 'function customerAuthFailureKindV289');
  assert.match(otp, /customerAuthErrorMessageV289\(error,'otp_verify'\)/);
  assert.match(otp, /customerAuthErrorMessageV289\(error,'otp_send'\)/);
});

test('G6: registration keeps one idempotency key per unchanged attempt', () => {
  const profile = block('function renderCustomerRegistrationProfile', 'async function renderCustomerRegistration(');
  assert.match(profile, /if\(!registrationAttemptV289\|\|registrationAttemptV289\.key!==attemptKeyV289\)/);
  assert.match(profile, /p_idempotency_key:registrationAttemptV289\.id/);
  assert.doesNotMatch(profile, /p_idempotency_key:crypto\.randomUUID\(\)/,
    'a new key per click spends a rate-limit slot per click instead of replaying the same attempt');
});

test('G6: try_later renders the retry window the server actually returned', () => {
  const profile = block('function renderCustomerRegistrationProfile', 'async function renderCustomerRegistration(');
  assert.match(profile, /outcome==='try_later'/);
  assert.match(profile, /Math\.ceil\(Number\(result\?\.data\?\.retry_after_seconds\|\|0\)\/60\)/);
  assert.match(profile, /Try again in about \$\{minutes\} minute/);
  assert.match(profile, /kind==='network'/, 'a dead connection is not a server refusal');
});

/* ------------------------------------------------ G7: an unavailable channel offers no controls */

test('G7: sms:false renders one honest card, no fields and no security check', () => {
  const start = block('async function renderCustomerOtpStart', 'async function runCustomerRegistrationProfileSubmission');
  const unavailable = start.slice(start.indexOf('if(!smsAvailable){'), start.indexOf("customerRegistrationShell(`<section class=\"card\" aria-labelledby=\"customerOtpStartTitle\""));
  assert.ok(unavailable.length > 0, 'the unavailable branch must come BEFORE the form is painted');
  assert.match(unavailable, /Sign-up by SMS is unavailable/);
  assert.match(unavailable, /No account has been created/);
  assert.doesNotMatch(unavailable, /authChallengeHtml|customerOtpSend|customerPhone/,
    'no dead controls and no eternal "Loading security check…"');
  assert.match(unavailable, /id="customerOtpBack"/, 'the one control offered must work');
  assert.doesNotMatch(start, /if\(!smsAvailable\)return;/,
    'the late guard that left a fully painted, permanently disabled form is gone');
});

/* ------------------------------------------------------------------------- smaller findings */

test('Messages and Profile offer a way back to Home', () => {
  const messages = block('async function renderCustomerMessages', 'const CUSTOMER_CONSENT_CATEGORY_LABELS_V282');
  assert.match(messages, /active:'messages',backTo:'#\/wallet'/);
  const profile = block('async function renderCustomerProfile', 'async function renderCustomerQrJoin');
  assert.match(profile, /active:'profile',backTo:'#\/wallet'/);
  assert.match(app, /if\(\$\('walletBack'\)\)\$\('walletBack'\)\.onclick=\(\)=>nav\(backHref\)/);
});

test('inbox reminder preferences are reachable from the surface that actually renders', () => {
  const inbox = block('async function renderCustomerInAppInbox', 'async function renderCustomerNotificationPreferences');
  assert.doesNotMatch(inbox, /\$\{global\?''/, 'the preferences host is no longer suppressed on the only reachable surface');
  assert.match(inbox, /if\(global\)return renderGlobalPreferencesV289\(preferenceHost\)/);
  assert.match(inbox, /details\.ontoggle=async\(\)=>\{/, 'each business loads its settings only when opened');
  assert.match(inbox, /customer_set_in_app_inbox_preferences/);
  // the lazy grouping is what keeps Messages at the same number of reads it had before
  const eager = inbox.match(/renderGlobalPreferencesV289=preferenceHost=>\{[\s\S]*?\n  \};/)[0];
  assert.doesNotMatch(eager.slice(0, eager.indexOf('ontoggle')), /customer_get_in_app_inbox_preferences/);
});
