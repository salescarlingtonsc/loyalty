import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = (readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
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
const packages = section('async function packagesPage(options)', '/* ---------- branches (owner-only) ----------');
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
  assert.match(shell, /grow:\(hashParam,routedFocus\)=>growPage\('overview',hashParam,routedFocus,\{fromRouteV288:true\}\)/);
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
  /* V257 kept package SALES collapsed behind a <details> drawer. V373 moves them into the Add
     item sheet's "Sell package" tab, which protects the same thing more strongly: they are not
     on the main screen at all, and the sheet cannot be collapsed by a redraw. */
  assert.match(recordSale, /\{key:'sellpackage',label:'Sell package'\}/);
  assert.match(recordSale, /sellpackage:canPkg&&\(catalog\.packages\|\|\[\]\)\.length>0/);
  assert.match(recordSale, /String\(line\.ref\)===String\(id\)/);
  assert.doesNotMatch(recordSale, /line\.ref_id/);
  assert.match(recordSale, /class="till-choice-qty"/);
  /* V211: this used to assert `const ownedPackages=''` — it pinned the STUB that emptied the
     owned-package list. That stub is why an owner could not spend a session a customer had
     already paid for, and it stood in direct contradiction to the v102 test, which requires the
     till to show owned packages and consume sessions. The owner reported the symptom directly:
     "i still dont see the package here in record sale - not able to use sessions".
     The compactness this test protects is real and is still asserted above: package SALES stay
     collapsed behind the <details> summary. Spending an existing session is the common act at a
     counter and is not hidden. */
  assert.match(recordSale, /const ownedPackages=ownedPkgs\.length/);
  assert.match(recordSale, /Use an existing customer package/);
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
  /* V373: services and products are drawn by ONE tile builder, so the photo lookup is one call
     for both kinds rather than two copies that could drift apart. */
  assert.match(recordSale, /catalogueImageUrlV158\(item\)/);
  assert.match(recordSale, /\.\.\.catalog\.services\.map\(item=>\(\{type:'service',item\}\)\)/);
  assert.match(recordSale, /\.\.\.\(catalog\.products\|\|\[\]\)\.map\(item=>\(\{type:'product',item\}\)\)/);
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
