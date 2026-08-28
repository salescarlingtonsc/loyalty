/* nestly_v588 — owner report: "even using the reference code to sign up as staff, during sign up
   process - it is in a mess" (pre-go-live 2026-08-29). The server side (migration nestly_v588,
   already applied to prod) changed three contracts: accept_invite now returns
   {status:'awaiting_approval'|'approved', business_id, business_slug, business_name, message,
   replayed?} instead of {status,business_name,message}, and replays for the same user succeed
   instead of raising; preview_staff_invite can answer 'awaiting_approval'; and
   create_staff_reference_code_v217 gained a p_rotate argument that defaults to false (return the
   existing pending code, reused:true) with an explicit rotate path.

   The client had three real bugs on top of that: (1) the accept handler assigned accept_invite's
   own {status,message} payload onto S.biz, corrupting the in-memory business object, and toasted
   "Welcome to the team" at someone the server had just parked awaiting_approval; (2) both the
   accept screen and the auth screen refused a code the moment preview_staff_invite answered
   anything other than 'valid', including the new (correct) 'awaiting_approval' answer, so a
   returning code holder could never get back in; (3) a person holding only a reference code had
   no door in from the ordinary business sign-in screen at all.

   These assertions pin the client half; the rolled-back production chain proves the server half. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start} … ${end}`);
  return app.slice(from, to);
};

const acceptFn = section('function renderBusinessStaffInviteAcceptV151(code){', 'function businessApplicationCopy(locale,key)');
const authFn = section('function renderStaffInviteAuthV151(mode=', 'function renderBusinessStaffInviteAcceptV151(code){');
const previewMarkupFn = section('function staffInvitePreviewMarkupV151(preview){', 'async function previewStaffInviteV151(');
const renderAuthFn = section('function renderAuth(mode=', 'function validNewPassword(password){');
const referenceHandler = section('window.staffReferenceCodeV217=async(staffId,button)=>{', 'window.rvInv=async(id)=>{');
const routerSlice = section('const staffInviteCodeV151=businessStaffInviteCodeV151();', 'function renderShell(page)');
const businessSignupChoiceFn = section('function renderBusinessSignupChoice(){', 'function renderBusinessDemoRequest(){');

test('the accept handler never assigns accept_invite\'s payload onto S.biz', () => {
  // Matches a live assignment statement, not the explanatory comment quoting the old bug.
  assert.doesNotMatch(acceptFn, /S\.biz=data;/,
    'accept_invite\'s {status,business_id,business_slug,business_name,message} shape must never become the business object');
  assert.match(acceptFn, /const slug=data\?\.business_slug\|\|'';/);
  assert.match(acceptFn, /nav\(`#\/workspace\/\$\{encodeURIComponent\(slug\)\}\/dashboard`\)/,
    'a successful accept still lands on the workspace route, which owns the awaiting/approved rendering');
});

test('the accept handler toasts the server\'s own message and distinguishes approved from awaiting_approval', () => {
  assert.match(acceptFn, /data\?\.status==='approved'\?'Welcome back — opening the workspace':\(data\?\.message\|\|'Joined — waiting for the owner to approve you'\)/);
  assert.doesNotMatch(acceptFn, /toast\('Welcome to the team'\)/,
    'the old toast lied to a person the server had just parked awaiting approval');
});

test('the accept screen lets a replayed (awaiting_approval) preview through to accept_invite, the real authority', () => {
  assert.match(acceptFn, /preview\?\.status&&preview\.status!=='valid'&&preview\.status!=='awaiting_approval'/,
    'only a genuinely dead preview status (invalid/expired/revoked/already_used/business_unavailable) refuses locally now');
});

test('staffInvitePreviewMarkupV151 has an awaiting_approval branch, not lumped into the error map', () => {
  assert.match(previewMarkupFn, /if\(preview\.status==='awaiting_approval'\)\{/);
  assert.match(previewMarkupFn, /waiting for the owner's approval/);
  assert.match(previewMarkupFn, /sign in with the account you created/);
  // Must not appear in the error-messages map used for the terminal statuses.
  const messagesMap = previewMarkupFn.slice(previewMarkupFn.indexOf('const messages='));
  assert.doesNotMatch(messagesMap, /awaiting_approval/);
});

test('renderStaffInviteAuthV151 allows awaiting_approval through both the Google and password continue gates', () => {
  const gates = authFn.match(/preview\?\.status&&preview\.status!=='valid'&&preview\.status!=='awaiting_approval'/g) || [];
  assert.equal(gates.length, 2, 'both the Google-continue gate and the password-continue gate must allow awaiting_approval');
});

test('renderStaffInviteAuthV151 subtitle no longer claims Stripe is irrelevant, and the two modes are a real segmented control', () => {
  assert.doesNotMatch(authFn, /Stripe is not required for invited staff/);
  assert.match(authFn, /Enter the code your business gave you, then create your account — or sign in if you already have one\./);
  assert.match(authFn, /<div class="v150-segment" role="group" aria-label="Account"/);
  assert.match(authFn, /id="staffInviteSignInTab" aria-pressed="\$\{mode==='in'\}"/);
  assert.match(authFn, /id="staffInviteSignUpTab" aria-pressed="\$\{mode==='up'\}"/);
  // Same ids, same handlers as before — only the wrapper/markup changed.
  assert.match(authFn, /\$\('staffInviteSignInTab'\)\.onclick=\(\)=>renderStaffInviteAuthV151\('in',\$\('staffInviteCodeV151'\)\.value\)/);
  assert.match(authFn, /\$\('staffInviteSignUpTab'\)\.onclick=\(\)=>renderStaffInviteAuthV151\('up',\$\('staffInviteCodeV151'\)\.value\)/);
});

test('a fresh reference code defaults to Create account, not Sign in, at both entry points', () => {
  assert.match(routerSlice, /renderStaffInviteAuthV151\('up',staffInviteCodeV151\)/,
    'the router\'s direct staff-invite-link entry must default to signup — a code holder is almost always new');
  assert.match(businessSignupChoiceFn, /\$\('joinBusinessChoice'\)\.onclick=\(\)=>renderStaffInviteAuthV151\('up',businessStaffInviteCodeV151\(\)\)/);
});

test('the accept screen\'s "different account" path is untouched and still goes back to sign-in', () => {
  assert.match(acceptFn, /\$\('staffInviteAcceptSignOut'\)\.onclick=async\(\)=>\{killChannels\(\);await sb\.auth\.signOut\(\);resetClientSessionState\(\);renderStaffInviteAuthV151\('in',normalized\)\}/,
    'an already-authenticated person choosing "use a different account" is a distinct, existing-account path and must keep defaulting to sign-in');
});

test('renderAuth grows a staff-invite door on the business side only, wired to the up-mode invite screen', () => {
  assert.match(renderAuthFn, /id="authStaffInviteDoorV588"/);
  assert.match(renderAuthFn, /Joining a team\? Enter your staff invite code/);
  // Gated the same way the pre-existing "New here? Sign up" button is: admin?'':...
  assert.match(renderAuthFn, /\$\{admin\?'':'<button type="button" class="btn ghost sm" id="authStaffInviteDoorV588"/);
  assert.match(renderAuthFn, /if\(\$\('authStaffInviteDoorV588'\)\)\$\('authStaffInviteDoorV588'\)\.onclick=\(\)=>renderStaffInviteAuthV151\('up',businessStaffInviteCodeV151\(\)\)/);
});

test('the "Give app access" RPC call passes p_rotate, and a rotate path exists', () => {
  const initialCall = referenceHandler.slice(0, referenceHandler.indexOf('document.querySelector'));
  assert.match(initialCall, /sb\.rpc\('create_staff_reference_code_v217',\{p_business:S\.biz\.id,p_staff:staffId,p_rotate:false\}\)/);
  assert.match(referenceHandler, /id="staffReferenceRotateV217"/);
  assert.match(referenceHandler, /New code instead/);
  assert.match(referenceHandler, /sb\.rpc\('create_staff_reference_code_v217',\{p_business:S\.biz\.id,p_staff:staffId,p_rotate:true\}\)/);
});

test('the modal offers Copy invite link via the shared staffInviteLinkV151 helper, and shows a reused note', () => {
  assert.match(referenceHandler, /id="staffReferenceCopyLinkV217"/);
  assert.match(referenceHandler, /Copy invite link/);
  assert.match(referenceHandler, /copyTextToClipboard\(staffInviteLinkV151\(code\),\{/);
  assert.match(referenceHandler, /send it to them on WhatsApp/);
  assert.match(referenceHandler, /payload\?\.reused\?`<p class="muted small"/);
  assert.match(referenceHandler, /This is the code you already created — it still works/);
  assert.match(referenceHandler, /payload\?\.restricted_to_email/);
  assert.match(referenceHandler, /This code only works for/);
  // No dynamic aria-label/title/placeholder interpolation on this workspace surface.
  assert.doesNotMatch(referenceHandler, /(aria-label|title|placeholder)="\$\{/);
  // Merchant name still carries the required marker.
  assert.match(referenceHandler, /class="staff-reference-code-v217" data-merchant-content/);
});

test('the modal instructions reflect the link-first flow', () => {
  assert.match(referenceHandler, /Send \$\{esc\(name\)\} the invite link \(or read them the code\)\./);
  assert.match(referenceHandler, /They create their own account — the code is filled in for them from the link\./);
  assert.match(referenceHandler, /their job title, commission, hours and past sales stay as they are\. No details are re-entered\./);
});

test('nestly_v588 the onboarding join box has the same fix — no S.biz corruption anywhere', () => {
  /* The invite-accept page was not the only accept_invite caller: the onboarding screen's own
     "Enter your invite code" box carried the identical S.biz=data + premature-welcome bug. Assert
     over the WHOLE file so a third call site can never reintroduce it. */
  assert.doesNotMatch(app, /S\.biz=data;/);
  const onboardJoin = app.slice(app.indexOf("$('join').onclick=async()"), app.indexOf("$('out').onclick="));
  assert.match(onboardJoin, /data\?\.business_slug/);
  assert.match(onboardJoin, /#\/workspace\/\$\{encodeURIComponent\(joinSlugV588\)\}\/dashboard/);
  assert.doesNotMatch(onboardJoin, /Welcome to the team/);
});
