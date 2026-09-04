import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = (readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));

function section(start, end) {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

const choice = section('function renderBusinessSignupChoice(){', 'function renderBusinessDemoRequest(){');
const demo = section('function renderBusinessDemoRequest(){', 'function renderStaffInviteAuthV151(');
const ownerSignup = section('function renderBusinessApplication(){', 'async function renderApprovedBusinessInviteSignup(');
const manualFallback = section('function manualBusinessApplicationFallbackHtml', 'function renderOnboard(){');
const onboard = section('function renderOnboard(){', '/* ============================================================================');

test('V167 public business signup asks for intent before collecting business data', () => {
  assert.match(choice, /How would you like to use Peekaa\?/);
  assert.match(choice, /requestDemoChoice/);
  assert.match(choice, /Request a demo/);
  assert.match(choice, /No account or workspace is created/);
  assert.match(choice, /Set up business/);
  assert.match(choice, /Razorpay Checkout or manual payment approval/);
  assert.match(choice, /Join an existing business/);
  assert.match(choice, /requestDemoChoice'\)\.onclick=\(\)=>renderBusinessDemoRequest\(\)/);
  assert.match(choice, /startBusinessChoice'\)\.onclick=\(\)=>\{return renderBusinessApplication\(\)\}/);
  assert.match(choice, /joinBusinessChoice'\)\.onclick=\(\)=>renderStaffInviteAuthV151/);
});

test('V167 demo path is no-account consultant contact only', () => {
  assert.match(demo, /Request a Peekaa demo/);
  assert.match(demo, /Demo request only/);
  assert.match(demo, /Peekaa consultants will contact you/);
  assert.match(demo, /No owner account, workspace, login, Razorpay Checkout, or Super Admin approval is created/);
  /* v292 replaced the mailto with a RECORDED demo request (submit_demo_request_v292) — a
     consultant follows up from the record instead of hoping an email client opens. The
     invariant this test guards is unchanged and pinned below: no account, no workspace, no
     checkout is created. */
  assert.match(demo, /sb\.rpc\('submit_demo_request_v292'/);
  assert.match(demo, /demoContactName/);
  assert.match(demo, /demoBusinessName/);
  assert.match(demo, /demoContactEmail/);
  assert.match(demo, /demoContactPhone/);
  assert.doesNotMatch(demo, /sb\.auth\.signUp/);
  assert.doesNotMatch(demo, /start_self_serve_business_v130/);
  assert.doesNotMatch(demo, /request_self_serve_checkout_v130/);
  assert.doesNotMatch(demo, /request_self_serve_manual_application_v159/);
  assert.doesNotMatch(demo, /accept_invite/);
});

test('V167 set-up-business copy separates Razorpay activation from manual approval', () => {
  assert.match(ownerSignup, /Create your Peekaa owner account/);
  assert.match(ownerSignup, /choose Razorpay Checkout or manual payment approval/);
  assert.match(ownerSignup, /Razorpay opens access only after verified payment/);
  assert.match(ownerSignup, /manual payment waits for Super Admin approve\/reject/);
  assert.match(ownerSignup, /Razorpay payment auto-activates after verified payment/);
  assert.match(ownerSignup, /manual payment goes to Super Admin for approve\/reject/);
  assert.match(ownerSignup, /businessApplicationBack'\)\.onclick=\(\)=>renderBusinessSignupChoice\(\)/);
  assert.doesNotMatch(ownerSignup, /Request demo|demo requests|product demo/);
});

test('V167 manual payment remains authenticated Super Admin approve or reject flow', () => {
  assert.match(manualFallback, /Request manual payment approval/);
  assert.match(manualFallback, /bank transfer, cash, or another manual arrangement instead of Razorpay/);
  assert.match(manualFallback, /Super Admin reviews and approves or rejects this manual-payment application/);
  assert.match(manualFallback, /does not activate a workspace, open Razorpay Checkout, or record payment/);
  assert.match(manualFallback, /request_self_serve_manual_application_v159/);
  assert.match(manualFallback, /Sending this manual-payment application to the Peekaa admin queue/);
  assert.match(manualFallback, /approve or reject it after payment is verified/);
  assert.doesNotMatch(manualFallback, /Request demo|product demo|manual help|within 48 hours/i);
  // The Razorpay-vs-manual explanation moved into renderBusinessApplication when the application
  // flow was split out of onboarding; assert it where it now lives.
  const application=section('function renderBusinessApplication','function renderOnboard(){');
  assert.match(application, /Razorpay payment auto-activates after verified payment; manual payment goes to Super Admin for approve\/reject\./);
  assert.match(application, /Super Admin reviews and approves or rejects this manual-payment application/);
});
