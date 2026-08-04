import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../../supabase/migrations/20260804054949_nestly_v158_catalogue_media.sql', import.meta.url), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

const routing = section('async function route(){', '/* ---------- customer wallet ---------- */');
const staffInvite = section('function staffInviteOAuthRedirectV158(code){', 'function renderBusinessSignupChoice(){');
const staffInviteAuth = section('function renderStaffInviteAuthV151', 'function renderBusinessApplication(){');
const branches = section('async function branchesPage()', 'async function customerIntelligencePage()');
const packages = section('async function packagesPage()', '/* ---------- branches (owner-only) ----------');
const recordSale = section('function drawCartComposer(){', 'async function servicesPage()');
const services = section('async function servicesPage()', 'async function referralsPage()');
const shell = section('function renderShell(page){', 'async function dashboard(){');
const mediaHelpers = section('const CATALOGUE_MEDIA_MAX_BYTES_V158', 'function workspaceLogoPublishArgsV96');
const checkoutCatalogue = section('async function loadCheckoutCatalogue(branchId=null)', "$('bsave').onclick=async()=>{");
const customerPortal = section('function customerFeatureCardMarkupV156', 'function showCustomerPromotionPopupV122');
const profile = section('function userDisplayNameV158()', 'function profileHtml()');
const appointments = section('async function appointmentsPage()', 'async function waitlistPage()');

test('V158 makes /programmes deep links resolve to the existing Programmes/Grow route', () => {
  assert.match(routing, /if\(h==='#\/programmes'\|\|h\.startsWith\('#\/programmes\/'\)\)h=h\.replace\('#\/programmes','#\/grow'\)/);
  assert.match(shell, /grow:\(hashParam,routedFocus\)=>growPage\('overview',hashParam,routedFocus\)/);
});

test('V158 allows invited staff to start Google sign-in while preserving server-side invite acceptance', () => {
  assert.match(staffInvite, /function staffInviteOAuthRedirectV158\(code\)/);
  assert.match(staffInvite, /url\.searchParams\.set\('staff_invite',normalizeCompanyInviteCodeV151\(code\)/);
  assert.match(staffInviteAuth, /businessGoogleButtonHtml\('staffInviteGoogleV158'\)/);
  assert.match(staffInviteAuth, /provider:'google'/);
  assert.match(staffInviteAuth, /redirectTo:staffInviteOAuthRedirectV158\(code\)/);
  assert.match(app, /sb\.rpc\('accept_invite'/);
});

test('V158 exposes staff management from branch settings without duplicating the staff system', () => {
  assert.match(branches, /href="#\/staffmembers"/);
  assert.match(branches, /Add or manage staff/);
  assert.match(branches, /Tick who works here/);
});

test('V158 keeps next-phase and inventory controls hidden while sale selection remains compact', () => {
  assert.match(services, /const showServiceProductDeductionV157=false/);
  assert.match(services, /if\(showServiceProductDeductionV157\)\{/);
  assert.match(recordSale, /<details class="till-sale-package-options"><summary>Sell package<\/summary>/);
  assert.match(recordSale, /String\(line\.ref\)===String\(id\)/);
  assert.doesNotMatch(recordSale, /line\.ref_id/);
  assert.match(recordSale, /class="till-choice-qty"/);
  assert.match(recordSale, /const ownedPackages=''/);
});

test('V158 replaces unclear package Restore wording with Undo session use', () => {
  assert.match(packages, /Use Undo session use only when a package session was deducted by mistake/);
  assert.match(packages, />Undo session use<\/button>/);
  assert.match(packages, /Session added back · no refund/);
  assert.doesNotMatch(packages, />Restore session<\/button>/);
});

test('V158 product and service photos flow from owner upload to record sale and customer portal', () => {
  assert.match(migration, /business_get_catalogue_media_versions_v158/);
  assert.match(migration, /business_get_checkout_catalogue_v94/);
  assert.match(migration, /image_url/);
  assert.match(mediaHelpers, /business_get_catalogue_media_versions_v158/);
  assert.match(mediaHelpers, /p_asset_kind:assetKind/);
  assert.match(mediaHelpers, /data-catalogue-photo-kind-v158/);
  assert.match(services, /cataloguePhotoInputHtmlV158\(\{assetKind:'service'/);
  assert.match(checkoutCatalogue, /cataloguePhotoInputHtmlV158\(\{assetKind:item\.item_type/);
  assert.match(recordSale, /catalogueImageUrlV158\(s\)/);
  assert.match(recordSale, /catalogueImageUrlV158\(p\)/);
  assert.match(recordSale, /class="till-choice-image"/);
  assert.match(customerPortal, /customerMediaUrlV95\(item\?\.image_url\)/);
  assert.match(customerPortal, /class="customer-feature-image"/);
});

test('V158 profile and appointment flows expose branch/name/slot behaviours', () => {
  assert.match(profile, /userDisplayNameV158/);
  assert.match(profile, /hydrateProfileBranchSelectorV158/);
  assert.match(profile, /all branches/i);
  assert.match(appointments, /class="day-slot-button"/);
  assert.match(appointments, /data-service="\$\{esc\(calendarServiceId\)\}"/);
  assert.match(appointments, /openNewAppointmentForm\(\{\s*date:button\.dataset\.day,\s*staffId:button\.dataset\.staff,\s*time:button\.dataset\.time,\s*serviceId:button\.dataset\.service/s);
});
