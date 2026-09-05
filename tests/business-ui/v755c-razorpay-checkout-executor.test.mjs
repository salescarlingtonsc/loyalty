/* nestly_v755 (Razorpay swap, builder C / client scope) — replaces the client-facing assertions
   that used to live in tests/business-ui/v281-stripe-readiness.test.mjs.

   That file entangled three ownership domains in one suite: db/migrations SQL, the
   supabase/functions/stripe-billing-webhook and stripe-billing-command source, and app.js's
   self-service checkout executor. The webhook/command edge functions are renamed and rewritten
   for Razorpay by the migration/edge-function builders in this wave (see
   RAZORPAY_SWAP_SPEC.md); their own coverage — livemode-vs-key-prefix mode safety, the signed
   webhook contract, the durable-inbox re-drive schedule, the v281 SQL migration content — belongs
   in their v755 test files (tests/billing/v755-razorpay-*.test.mjs), not here.

   This file pins ONLY what app/app.js (the client) actually does: the self-service checkout
   executor still retries an 'uncertain' provider response with the SAME command id instead of
   minting a second one, both self-service surfaces still run through the one shared executor, the
   locked-workspace checkout door still reuses its stored command id, and the polling/") copy is
   Razorpay-branded rather than a leftover "Stripe" string. Same coverage intent as the retired
   file's client-side tests, ported onto the renamed invoke target. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
/* Tests that grep application code read the CONCATENATION of index.html + app.js (AGENTS.md). */
const app = readFileSync(join(root, 'app', 'index.html'), 'utf8')
  + readFileSync(join(root, 'app', 'app.js'), 'utf8');

const checkoutExecutor = app.slice(
  app.indexOf('async function runSelfServeCheckoutV281('),
  app.indexOf('function selfServePaymentReturnStateV286('));
assert.ok(checkoutExecutor.length > 200, 'the V281 checkout executor must be locatable');

test('v755 the checkout executor invokes razorpay-billing-command, not the retired stripe-billing-command', () => {
  assert.doesNotMatch(app, /invoke\('stripe-billing-command'/,
    'no client code may still call the retired Stripe edge function');
  assert.match(checkoutExecutor, /sb\.functions\.invoke\('razorpay-billing-command'/);
});

test('v755 an uncertain execution is retried with the SAME command id, as the server documents', () => {
  assert.match(checkoutExecutor,
    /if\(!result\?\.redirect_url&&\['uncertain','pending','processing'\]\.includes\(String\(result\?\.status\|\|''\)\)\)\{/,
    'a 202 uncertain response carries no redirect_url and is exactly the recoverable case');
  assert.match(checkoutExecutor,
    /const recovered=await sb\.functions\.invoke\('razorpay-billing-command',\{body:\{command_id:commandId\}\}\)/,
    'recovery is retry_same_command_id: a new command id would be a second Razorpay session');
  const replays = checkoutExecutor.match(/sb\.functions\.invoke\('razorpay-billing-command'/g) || [];
  assert.equal(replays.length, 2,
    'exactly one replay: the command holds a stable idempotency key, but a loop is not a retry policy');
});

test('v755/V627 the locked-workspace checkout reuses its command id rather than minting a second one', () => {
  const lockedDoor = app.slice(
    app.indexOf('function renderLockedWorkspacePaymentV620('),
    app.indexOf('function renderBusinessWorkspaceControl('));
  assert.ok(lockedDoor.length > 200, 'the v620 locked-workspace payment door must be locatable');
  assert.match(lockedDoor, /let requested=attempt\.command_id\?\{command_id:attempt\.command_id\}:null/,
    'a stored command id short-circuits the request: retrying must not ask for a new command');
  assert.match(lockedDoor, /if\(!requested\)\{[\s\S]*?request_billing_command_v124/,
    'and the request is issued ONLY when there is no stored command to reuse');
  assert.match(lockedDoor, /attempt\.command_id=requested\.command_id;writeBillingAttempt\(attempt\)/,
    'the id is persisted before the provider is called, so a reload recovers it');
  const lockedInvokes = lockedDoor.match(/sb\.functions\.invoke\('razorpay-billing-command'/g) || [];
  assert.equal(lockedInvokes.length, 1,
    'one execution per press; an uncertain result asks the owner to retry rather than looping');
});

test('v755 every non-redirect outcome re-enables the button and names what to do next, in Razorpay copy', () => {
  assert.match(app, /const SELF_SERVE_CHECKOUT_STATUS_V281=Object\.freeze\(\{/);
  for (const key of ['opening', 'request_failed', 'unreachable', 'pending']) {
    assert.match(app, new RegExp(`${key}:'`), `the ${key} outcome must have a named message`);
  }
  assert.match(app, /pending:'Razorpay has not returned a checkout page yet\. Retry/,
    'the terminal message must tell the owner to retry, not to wait for a webhook that will never come');
  assert.doesNotMatch(app, /has not returned a checkout page yet[^']*Stripe/,
    'the pending-checkout message must not still name Stripe');
  assert.match(checkoutExecutor + app.slice(app.indexOf('async function driveSelfServeCheckoutV281(')),
    /if\(button\)button\.disabled=false;/,
    'a disabled button with a pending message is the stuck state this executor exists to remove');
  assert.match(app,
    /const outcome=await runSelfServeCheckoutV281\(onboarding\);\s*\n\s*if\(outcome\.outcome==='redirect'\)\{location\.assign\(outcome\.redirectUrl\);return outcome\}/,
    'redirect is the only outcome that leaves the page');
});

test('v755 both self-service surfaces run the one executor, so the two copies cannot drift again', () => {
  const calls = app.match(/driveSelfServeCheckoutV281\(/g) || [];
  assert.equal(calls.length, 3,
    'one definition plus exactly two call sites: the workspace-control screen and the onboarding screen');
  assert.match(app,
    /\$\('selfServePay'\)\.onclick=\(\)=>driveSelfServeCheckoutV281\(/,
    'the single payment-pending screen must use the shared executor');
  assert.match(app, /renderSelfServePaymentPendingV286\(onboarding\);/,
    'the workspace-control branch must delegate rather than keep a second copy');
  assert.match(app,
    /const finishCheckout=\(onboarding,statusNode,button\)=>\s*\n?\s*driveSelfServeCheckoutV281\(onboarding,statusNode,button\);/,
    'the onboarding screen must use the shared executor');
  const inlineKeys = app.match(/nestly-self-serve-checkout-\$\{/g) || [];
  assert.equal(inlineKeys.length, 1, 'exactly one place may compute the checkout idempotency key');
});

test('v755 the poll that waits for provider confirmation is unchanged and still terminates, in Razorpay copy', () => {
  /* nestly_v782: the bound moved 15 -> 90 attempts in a9d5694d (nestly_v766) — deliberately, and
     for a measured reason: "the onboarding poll waits up to 3 minutes for the webhook (Razorpay
     took 66s), not 31s". The contract this test guards is that the poll is BOUNDED at all, not
     that it stops at any particular attempt, so the bound is pinned as a literal number rather
     than as 15 — a poll rewritten to `while(true)` or `if(attempts)` still fails here. */
  assert.match(app, /if\(attempts<90\)setTimeout\(poll,2000\)/,
    'the processing poll must stay bounded: an infinite poll is another way to be stuck');
  assert.match(app, /Razorpay has not confirmed activation yet\. Use Check payment again/,
    'the poll must end on an instruction, not on silence');
});

test('v755 no client entry point still calls the retired stripe-connect-command (PayNow QR / Connect onboarding)', () => {
  assert.doesNotMatch(app, /stripe-connect-command/,
    'Stripe Connect / PayNow POS has no Razorpay SG equivalent and was removed, not ported');
  assert.doesNotMatch(app, /paynow_qr/,
    'the PayNow QR till tender (provider-backed) must be gone; external/manual PayNow is unaffected');
});

test('v755 the billing settings screen offers Cancel/Resume instead of the retired Stripe billing portal', () => {
  assert.doesNotMatch(app, /execute\('create_portal'/,
    'Razorpay has no customer billing portal; create_portal must not be requested by the client');
  assert.doesNotMatch(app, /id="billingPortal"/);
  assert.doesNotMatch(app, /Open Stripe billing portal/);
  /* nestly_v758 renamed both buttons to the words an owner uses ("Cancel renewal" / "Resume
     renewal") and moved them onto the summary card. Same two commands, same two ids. */
  assert.match(app, /id="billingCancel">Cancel renewal</);
  assert.match(app, /id="billingResume">\$\{esc\(life\.resume_label\|\|'Resume renewal'\)\}</);
  /* nestly_v764 (owner ruling 4): a Razorpay cancel_at_cycle_end cannot be undone, so cancelling
     a renewal is a LOCAL intent (set_renewal_intent_v764) until the cron sends it shortly before
     the date. Both buttons still exist, with the same ids and the same two words; what changed is
     that they no longer reach the provider on the spot. */
  assert.match(app, /setRenewalIntentV764\(true\)/);
  assert.match(app, /setRenewalIntentV764\(false\)/);
  assert.match(app, /sb\.rpc\('set_renewal_intent_v764',\{p_business:S\.biz\.id,p_cancel:cancel\}\)/);
});
