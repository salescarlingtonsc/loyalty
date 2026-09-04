/* V286 — the acquisition funnel and the platform console's one-click money actions.

   The headline defect these tests exist for: a paying owner returning from Stripe was shown
   "Payment confirmation pending" underneath a "Complete secure payment" button — i.e. asked to
   pay a second time for the payment they had just made.

   The cause was not missing code. renderOnboard already understood the exact contract Stripe
   returns to (`/business#/onboarding/payment?status=processing`, see the stripe-billing-command
   success_url) and already polled for verified activation. It was UNREACHABLE:
   start_self_serve_business_v130 creates an ACTIVE owner staff row, so get_my_personas resolves
   a workspace and route() answered the return url through renderBusinessWorkspaceControl — a
   second, drifted copy of the same screen that read no status parameter at all. Two owners of
   one state, and the reachable one was the wrong one.

   The fix is the V281 shape: collapse the duplicate onto ONE renderer, and resolve
   #/onboarding/payment BEFORE persona resolution so the return route cannot be swallowed. That
   is a routing-ORDER property — it is invisible to any test that only checks the renderer
   exists — so the assertions below pin the order in source.

   Also pinned: the acquisition CTAs, the console decisions that used to commit on one click
   with an auto-written "reason", the first-run guide's durability, and the Turnstile fallback
   line. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '../..');
const read = (path) => readFileSync(resolve(root, path), 'utf8');

/* Tests that grep application code read the CONCATENATION of index.html + app.js (AGENTS.md). */
const appJs = read('app/app.js');
const app = read('app/index.html') + appJs;
const consoleJs = read('app/platform-console.js');
const landing = read('app/landing.html');
const brandConfig = read('app/brand-config.js');
const stripeCommand = read('supabase/functions/razorpay-billing-command/index.ts');

/* ── S1: the provider return route reaches the processing state ───────────── */

test('the route the provider returns to is still the one this fix targets', () => {
  assert.match(stripeCommand, /\/business#\/onboarding\/payment\?status=processing/,
    'success_url must still be the self-serve payment return route');
  assert.match(stripeCommand, /\/business#\/onboarding\/payment\?status=canceled/,
    'cancel_url must still be the self-serve payment return route');
});

test('#/onboarding/payment is resolved BEFORE any persona lookup', () => {
  const routeIndex = appJs.indexOf("if(String(h).split('?')[0]==='#/onboarding/payment')return renderOnboard();");
  assert.ok(routeIndex > 0, 'route() must answer #/onboarding/payment explicitly');

  /* The whole defect was ordering. A persona-bearing session — which EVERY self-serve owner is,
     because start_self_serve_business_v130 creates an active owner staff row — must not reach a
     persona branch before this line, or the return url is swallowed again. */
  const signedInGate = appJs.indexOf("if(!S.user)return renderAuth('in',{admin:requestedPlatformRoute});");
  assert.ok(signedInGate > 0 && signedInGate < routeIndex,
    'the payment-return route is for a signed-in owner, so it comes after the session gate');

  const businessBranch = appJs.indexOf("if(h==='#/business'){", routeIndex);
  assert.ok(businessBranch > routeIndex,
    'the #/business persona branch must come AFTER the payment-return route');

  const firstPersonaCall = appJs.indexOf("sb.rpc('get_my_personas')", signedInGate);
  assert.ok(firstPersonaCall > routeIndex,
    'no get_my_personas call may precede the payment-return route inside route()');
});

test('the processing state renders the waiting copy, not a second demand for payment', () => {
  const renderer = appJs.slice(
    appJs.indexOf('function renderSelfServePaymentPendingV286('),
    appJs.indexOf('function renderBusinessWorkspaceControl('));
  assert.ok(renderer.length > 0, 'the single payment-pending renderer must exist');
  assert.match(renderer, /Setting up your Peekaa workspace…/,
    'a returning payer sees a setting-up heading, not "Payment confirmation pending"');
  assert.match(renderer, /Open Razorpay Checkout again/,
    'the primary button must not read "Complete secure payment" in the processing state');
  assert.match(renderer, /Payment was returned from Razorpay/);
  assert.match(renderer, /Razorpay Checkout was closed without payment/,
    'the canceled variant must keep its own honest copy');
});

test('the processing state polls for verified activation and never self-certifies payment', () => {
  const renderer = appJs.slice(
    appJs.indexOf('function renderSelfServePaymentPendingV286('),
    appJs.indexOf('function renderBusinessWorkspaceControl('));
  assert.match(renderer, /attempts<15/, 'the activation poll must be bounded');
  assert.match(renderer, /setTimeout\(poll,2000\)/, 'the poll interval must survive');
  assert.match(renderer, /get_self_serve_checkout_v130/,
    'activation is read back from the server, never assumed from the return url');
  assert.match(renderer, /next\?\.status==='active'/,
    'only a server-confirmed active status may open the workspace');
});

test('the drifted second copy of the payment-pending screen is gone', () => {
  assert.equal(appJs.split("'Payment confirmation pending'").length - 1, 1,
    'exactly one place may render the payment-pending heading');
  assert.doesNotMatch(appJs, /businessControlPayStatus/,
    'renderBusinessWorkspaceControl must no longer carry its own checkout screen');
  assert.match(appJs, /renderSelfServePaymentPendingV286\(onboarding\);\n\s*\}\);/,
    'renderBusinessWorkspaceControl must delegate to the single renderer');
  assert.equal(appJs.split('function renderSelfServePaymentPendingV286(').length - 1, 1);
});

/* ── S5: activation lands on the guided setup, not an empty dashboard ─────── */

test('a freshly activated workspace opens the first-run setup guide', () => {
  assert.match(appJs, /function selfServeActivatedRouteV286\(slug\)\{\n\s*return `#\/workspace\/\$\{encodeURIComponent\(String\(slug\|\|''\)\)\}\/setup`;/,
    'the post-activation destination must be the setup guide');
  const renderer = appJs.slice(
    appJs.indexOf('function renderSelfServePaymentPendingV286('),
    appJs.indexOf('function renderBusinessWorkspaceControl('));
  assert.match(renderer, /nav\(selfServeActivatedRouteV286\(next\.business_slug\)\)/,
    'the success poll must send the owner to setup, not to #/dashboard');
  assert.match(appJs, /nav\(selfServeActivatedRouteV286\(data\.business_slug\|\|slug\)\)/,
    'the manual-payment activation path must land on the same guide');
});

test('the two setup-guide choices survive the browser session', () => {
  assert.match(app, /const setupFlagOn=key=>\{try\{return localStorage\.getItem\(key\)==='1'\}/,
    '"Don\'t show this again" must be read from localStorage');
  assert.match(app, /const setSetupFlag=\(key,on\)=>\{try\{if\(on\)localStorage\.setItem\(key,'1'\);else localStorage\.removeItem\(key\)\}/,
    'both guide flags must be written to localStorage');
  assert.doesNotMatch(app, /Setup guide hidden for this session/,
    'the copy must stop promising something narrower than the button says');
  assert.match(app, /Setup guide hidden on this device/);
});

/* ── S2: "Get started" and "Log in" stop being the same url ───────────────── */

test('every acquisition CTA opens the signup choice, not the sign-in form', () => {
  const acquisition = [...landing.matchAll(/<a\b[^>]*\bhref=["']([^"']*\/business[^"']*)["'][^>]*>([\s\S]*?)<\/a>/gi)]
    .map((m) => ({ href: m[1], label: m[2].replace(/<[^>]+>/g, '').trim() }))
    .filter((link) => /get started|start monthly/i.test(link.label));
  assert.ok(acquisition.length >= 6, `expected the CTA to repeat; found ${acquisition.length}`);
  for (const link of acquisition) {
    assert.equal(link.href, '/business?signup=1', `"${link.label}" must target the signup choice`);
  }
});

test('the header "Log in" deliberately keeps the bare sign-in url', () => {
  assert.match(landing, /<a class="head-login" href="\/business">Log in<\/a>/);
});

test('?signup=1 is a real contract the app answers', () => {
  assert.match(app, /h==='#\/business'&&new URLSearchParams\(location\.search\)\.get\('signup'\)==='1'\)return renderBusinessSignupChoice\(\)/,
    'the signup query must still resolve to the signup choice screen');
});

/* ── S6: the money terms are stated before signup ─────────────────────────── */

test('the pricing section states the currency and GST position before signup', () => {
  assert.match(landing, /Prices in SGD\. GST not charged\./);
});

test('the annual card carries the non-refundable term in the checkout page\'s own words', () => {
  const annual = landing.slice(landing.indexOf('<h3>Annual</h3>'), landing.indexOf('<h3>Monthly</h3>'));
  assert.match(annual, /Subscription fees are non-refundable after payment, except where required by law\./,
    'the term the owner meets at checkout must be visible before they commit');
  assert.match(app, /Subscription fees are non-refundable after payment, except where required by law/,
    'the landing copy must mirror the checkout page, not make a new claim');
});

test('the footer names the entity behind the product, and invents nothing else', () => {
  assert.match(brandConfig, /entityName: 'Nestly Technologies Pte\. Ltd\.'/);
  assert.match(landing, /Peekaa is a product of Nestly Technologies Pte\. Ltd\./);
  assert.doesNotMatch(landing, /\bUEN\b/, 'no registration number exists to publish, so none is published');
});

/* ── S7: no parameter that means nothing ──────────────────────────────────── */

test('the dead selfserve=1 confirmation parameter is gone', () => {
  assert.doesNotMatch(appJs, /searchParams\.set\('selfserve'/,
    'a routing parameter nothing reads is a contract that does not exist');
});

/* ── S3: the console cannot move money or close access on one click ───────── */

test('manual payment verification is confirmed before it commits', () => {
  assert.match(consoleJs, /function manualPaymentVerifyModalV286\(payment,context\)\{/);
  assert.match(consoleJs, /I opened the evidence and it matches this payment\./,
    'Verify keeps the lighter checkbox confirmation');
  assert.match(consoleJs,
    /main\.querySelectorAll\('\[data-v156-verify\]'\)[\s\S]{0,220}manualPaymentVerifyModalV286/,
    'the Verify button must open the modal, not call the RPC');
});

test('a manual payment rejection records the reason the operator actually typed', () => {
  assert.doesNotMatch(consoleJs, /Rejected by verifier after evidence review/,
    'the auto-written rejection reason asserted a review that may never have happened');
  assert.match(consoleJs, /function manualPaymentRejectModalV286\(payment,context\)\{/);
  const modalBody = consoleJs.slice(
    consoleJs.indexOf('function manualPaymentRejectModalV286('),
    consoleJs.indexOf('function documentResendModalV286('));
  assert.match(modalBody, /const reason=typedRejectionReasonV286\(form\);/);
  assert.match(modalBody, /p_reason:reason/, 'the stored reason must be the typed one');
});

test('a typed rejection reason has a minimum length and is never written on the operator\'s behalf', () => {
  assert.match(consoleJs, /const V286_MIN_REASON_LENGTH=12;/);
  assert.match(consoleJs, /if\(reason\.length<V286_MIN_REASON_LENGTH\)\{[\s\S]{0,240}throw new Error/,
    'a too-short reason must block the decision');
  assert.match(consoleJs, /This text is stored as the recorded decision reason\. Nothing is written on your behalf\./);
});

test('rejecting an account signup takes the same confirm-and-type path', () => {
  assert.match(consoleJs, /function accountSignupRejectModalV286\(context,userId,contactLabel,onDone\)\{/);
  const wiring = consoleJs.slice(
    consoleJs.indexOf('function wireAccountSignupQueue(context){'),
    consoleJs.indexOf('function paymentManagedSignupQueueHtml('));
  assert.match(wiring, /if\(status==='archived'\)\{[\s\S]{0,320}accountSignupRejectModalV286/,
    'Reject must open the modal; Approve and Pending stay one click because neither removes access');
  assert.doesNotMatch(wiring, /Rejected by platform admin\. Workspace access remains closed\./,
    'the auto-written rejection note must be replaced by the operator\'s own words');
  const modalBody = consoleJs.slice(
    consoleJs.indexOf('function accountSignupRejectModalV286('),
    consoleJs.indexOf('function wireAccountSignupQueue(context){'));
  assert.match(modalBody, /p_status:'archived',p_note:reason/);
});

test('resending a billing document is confirmed, and says a duplicate may arrive', () => {
  assert.match(consoleJs, /function documentResendModalV286\(delivery,context\)\{/);
  assert.match(consoleJs, /the customer may receive a duplicate/);
  assert.match(consoleJs,
    /main\.querySelectorAll\('\[data-v156-resend\]'\)[\s\S]{0,240}documentResendModalV286/,
    'the Resend button must open the modal, not queue on click');
});

/* ── S10: a slow security check offers a way out ──────────────────────────── */

test('a Turnstile-gated button gets a fallback line after 12 seconds', () => {
  assert.match(app, /const TURNSTILE_SLOW_FALLBACK_MS_V286=12000;/);
  assert.match(app, /slowFallback:'Taking long\? Reload to retry\.'/);
  assert.match(app, /setTimeout\(\(\)=>\{\n\s*if\(destroyed\|\|tokenSeenV286\)return;\n\s*slowNoteV286\.hidden=false;\n\s*\},TURNSTILE_SLOW_FALLBACK_MS_V286\)/,
    'the note must appear only while no token has arrived');
});

test('the fallback line is localised alongside the rest of the security copy', () => {
  for (const locale of ['zh-CN', 'ms']) {
    const table = app.slice(app.indexOf(`    ${locale === 'ms' ? 'ms' : `'${locale}'`}:{`));
    assert.ok(table.includes('slowFallback:'), `${locale} must carry the fallback line`);
  }
});

test('the fallback line never re-enables a gated button or bypasses the check', () => {
  const mount = appJs.slice(appJs.indexOf('async function mountTurnstile('),
    appJs.indexOf("const AUTH_TURNSTILE_SITE_KEY="));
  assert.doesNotMatch(mount, /onToken\('[^']+'\)/, 'no synthetic token may ever be produced');
  assert.match(mount, /tokenSeenV286=true;stopSlowNoteV286\(\)/,
    'a real token must clear the fallback line');
});
