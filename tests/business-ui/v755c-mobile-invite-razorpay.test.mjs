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

const mobileHelpers = section('function staffMobileActionsHtml(page)', '/* Owner ruling 2026-07-18');
const renderShell = section('function renderShell(page)', '  /* Loyalty and retention share one presentation surface');
const route = section('async function route()', 'function renderWorkspaceAccessUnavailable()');
const signup = section('const STAFF_INVITE_STORAGE_V151', 'function businessApplicationCopy(locale,key)');
const auth = section('function renderAuth(mode=', 'function validNewPassword(');
const onboard = section('function renderOnboard(){', '/* ============================================================================');
const dashboard = section('async function dashboard()', 'async function clientsPage()');
/* V243: the CSV-import block moved to the Customer Interface module, so this slice ends at the
   next marker still inside settingsPage. Same region, same intent. */
const settings = section('async function settingsPage()', '  /* ---------- billing (read-only) ---------- */');
const v151Migration = readFileSync(new URL('../../supabase/migrations/20260803210000_nestly_v151_mobile_staff_invites.sql', import.meta.url), 'utf8');

test('V151 mobile shell hides desktop controls and provides deliberate mobile controls', () => {
  assert.match(app, /\.mobile-page-title/);
  assert.match(app, /\.mobile-search-trigger/);
  assert.match(app, /\.mobile-search-sheet\[open\]/);
  assert.match(app, /\.dashboard-mobile-branch/);
  assert.match(app, /\.appbar>\.global-actions,\s*\.appbar>\.workspace-language-picker,\s*\.appbar>\.business-workspace-switch,\s*\.appbar>\.dashboard-appbar-branch\{display:none!important\}/);
  assert.match(renderShell, /mobileWorkspaceTitleHtml\(page\)/);
  assert.match(renderShell, /mobileSearchShellHtml\(\)/);
  assert.match(renderShell, /wireMobileSearchShell\(\)/);
  assert.match(mobileHelpers, /workspaceLanguageMobileV151/);
  assert.match(mobileHelpers, /mobile-workspace-summary/);
});

test('V151 mobile customer search uses existing till/customer routes instead of a new query path', () => {
  assert.match(mobileHelpers, /function runWorkspaceCustomerLookup\(query\)/);
  assert.match(mobileHelpers, /pendingTillPhone=digits/);
  assert.match(mobileHelpers, /pendingCustomerSearch=q/);
  assert.match(mobileHelpers, /goTo\('#\/till'\)/);
  assert.match(mobileHelpers, /goTo\('#\/clients'\)/);
  assert.match(mobileHelpers, /wireGlobalActions/);
});

test('V151 signup entry separates new business from invited staff', () => {
  assert.match(auth, /if\(!admin&&mode==='up'\)return renderBusinessSignupChoice\(\)/);
  assert.match(signup, /How would you like to use Peekaa\?/);
  assert.match(signup, /Request a demo/);
  assert.match(signup, /No account or workspace is created/);
  assert.match(signup, /Set up business/);
  assert.match(signup, /Razorpay Checkout or manual payment approval/);
  assert.match(signup, /Join an existing business/);
  assert.match(signup, /Company invite code/);
  /* nestly_v588 (owner: staff signup "in a mess"): the reassuring-but-irrelevant "Stripe is not
     required for invited staff" line is gone from the invite screen's subtitle — replaced by a
     plain "enter the code, then create your account or sign in" instruction. Pinned in the
     v588 test file, not here. */
  assert.doesNotMatch(signup, /Stripe is not required for invited staff/);
  assert.match(signup, /Enter the code your business gave you, then create your account — or sign in if you already have one\./);
});

test('V151 company invite direct links reuse staff_invites and accept_invite', () => {
  assert.match(signup, /STAFF_INVITE_STORAGE_V151/);
  assert.match(signup, /businessStaffInviteCodeV151/);
  assert.match(signup, /staffInviteLinkV151/);
  assert.match(signup, /previewStaffInviteV151/);
  assert.match(signup, /\/business/);
  assert.match(signup, /staff_invite/);
  assert.match(signup, /preview_staff_invite/);
  assert.match(signup, /sb\.rpc\('accept_invite',\{p_code:normalized\}\)/);
  assert.match(signup, /The company, role, module access, expiry, and reuse rules come from the invitation record/);
  assert.match(route, /staffInviteCodeV151/);
  /* nestly_v588: a fresh reference-code link is almost always a brand-new teammate, so the
     unauthenticated router entry now defaults to Create account ('up'), not Sign in ('in'). */
  assert.match(route, /renderStaffInviteAuthV151\('up',staffInviteCodeV151\)/);
  assert.match(route, /renderBusinessStaffInviteAcceptV151\(staffInviteCodeV151\)/);
});

test('V151 owner invite UI shows copy code and copy invite link actions', () => {
  assert.match(settings, /Create company invite/);
  assert.match(settings, /They can choose “Join an existing business” during sign-up/);
  assert.match(settings, /staff-invite-code/);
  assert.match(settings, /Copy code/);
  assert.match(settings, /Copy invite link/);
  assert.match(settings, /window\.cpInvLink/);
  assert.match(settings, /staffInviteLinkV151\(data\.code\)/);
});

test('V151 staff invite migration enforces email restriction and one-time server acceptance', () => {
  assert.match(v151Migration, /create or replace function public\.preview_staff_invite\(p_code text\)/);
  assert.match(v151Migration, /grant execute on function public\.preview_staff_invite\(text\) to anon, authenticated/);
  assert.match(v151Migration, /for update/);
  assert.match(v151Migration, /company invite is restricted to another email/);
  assert.match(v151Migration, /status = 'accepted'/);
  assert.match(v151Migration, /accepted_user_id = auth\.uid\(\)/);
  assert.match(v151Migration, /status in \('pending','accepted','revoked','expired'\)/);
  assert.match(v151Migration, /raise exception 'company invite has already been used'/);
  assert.match(v151Migration, /raise exception 'company invite has been revoked'/);
  assert.match(v151Migration, /raise exception 'company invite has expired'/);
});

test('V151/v755 Razorpay return polls provider-confirmed self-service status and never trusts success URL alone', () => {
  /* V286: the poll and the ?status= reading moved out of renderOnboard into the single
     payment-pending renderer, because renderOnboard was not the screen the provider return
     actually reached. The contract this test is about is unchanged; only its address is.
     nestly_v755: the provider is now Razorpay, not Stripe — see RAZORPAY_SWAP_SPEC.md. */
  const pending = section('function renderSelfServePaymentPendingV286(', 'function renderBusinessWorkspaceControl(');
  assert.match(pending, /Setting up your Peekaa workspace/);
  assert.match(pending, /selfServePaymentReturnStateV286\(\)/);
  assert.match(pending, /get_self_serve_checkout_v130/);
  assert.match(pending, /if\(next\?\.status==='active'\)/);
  assert.match(pending, /Checkout success pages do not unlock access; provider-confirmed payment does/);
  assert.match(pending, /Razorpay confirmation is still processing/);
  /* V281: the checkout request moved into the shared runSelfServeCheckoutV281 executor. The
     poll this test is about is unchanged and still lives in renderOnboard. */
  assert.match(onboard, /driveSelfServeCheckoutV281\(onboarding,statusNode,button\)/);
  assert.match(section('async function runSelfServeCheckoutV281(', 'function renderBusinessWorkspaceControl('),
    /request_self_serve_checkout_v130/);
});

test('V151 dashboard charts show empty states instead of misleading axes', () => {
  assert.match(dashboard, /dashboard-chart-empty/);
  /* V287 retarget: V225 deleted #dashboardReportingScopeWrap from the markup but left the
     selector call behind, and renderReportingScopeSelectorV155 fires onChange immediately when
     its target is missing — so the Dashboard ran its whole load twice per open. The call is
     gone; what this test actually guards is that the reporting scope still reaches the RPCs. */
  assert.doesNotMatch(dashboard, /renderReportingScopeSelectorV155\(/);
  assert.match(dashboard, /currentReportingScopePayloadV155/);
  assert.match(dashboard, /No revenue recorded in this period/);
  assert.match(dashboard, /More activity is needed to show a trend/);
  // Chart empty states were reworded to say what to do next, not just what is missing.
  assert.match(dashboard, /No visits recorded in this period\. Record a completed sale/);
  assert.match(dashboard, /No customer age data recorded yet/);
  assert.match(dashboard, /No customer gender data recorded yet/);
  assert.match(dashboard, /revenueHasTrend/);
});
