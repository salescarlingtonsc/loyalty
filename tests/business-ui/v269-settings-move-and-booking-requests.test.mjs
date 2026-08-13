/* V269 — two owner reports.

   (A) Settings screenshot, the first three tabs circled: "delete these from settings, all put
   inside under Customer Interface", with the target structure drawn as
   Customer Interface → Workspace & Brand / Customer Programme / Interface.
   V243 and V259 had moved the panels but deliberately left labelled pointer tabs behind. The
   owner has now read those pointers and asked for them to go too, so this file protects the
   deletion AND the thing the deletion must not break: each panel and each save handler still
   exists exactly ONCE in the bundle, and the owner gate is untouched on both sides.

   (B) Appointments screenshot: "need to add some buttons to see appointment requests by customer,
   when customer book for appointment, need some place to accept / decline". The accept and
   decline actions already existed on Bookings, backed by the one lifecycle RPC
   staff_decide_booking_request_v73 (confirm/decline, idempotent by row lock, audited). The gap
   was discoverability from the calendar. So the contract here is a counted signpost that hands
   off to that one surface — NOT a second decision path. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
/* Tests that grep application code read the CONCATENATION of index.html + app.js (AGENTS.md). */
const app = `${readFileSync(join(root, 'app', 'index.html'), 'utf8')}\n${readFileSync(join(root, 'app', 'app.js'), 'utf8')}`;

function section(start, end) {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

const settings = section('async function settingsPage()', '/* ---------- billing (read-only) ---------- */');
const customerInterface = section('async function customerInterfacePageV243(hashParam)', '/* ---------- phone country-code picker');
const appointments = section('async function appointmentsPage()', 'async function waitlistPage()');
const bookings = section('async function bookingsPage()', 'function productProfitabilityV122(');

/* ------------------------------------------------------------------ (A1) the tabs are gone */

test('V269 Settings keeps only the three operations tabs', () => {
  const tabs = section('class="settings-tabs" data-workspace-i18n', '<section class="settings-panel"');
  assert.deepEqual([...tabs.matchAll(/data-settab="([a-z]+)"/g)].map((m) => m[1]),
    ['modules', 'catalogue', 'team']);
  for (const gone of ['workspace', 'programme', 'fields']) {
    assert.doesNotMatch(settings, new RegExp(`data-settab="${gone}"`));
    assert.doesNotMatch(settings, new RegExp(`id="setpanel-${gone}"`));
  }
});

test('V269 the "Moved to Customer Interface" placeholder cards are deleted, not kept', () => {
  assert.doesNotMatch(app, /settingsMovedToCustomerInterfaceCardV243/,
    'the pointer card helper must not survive anywhere in the bundle');
  assert.doesNotMatch(app, /Moved to Customer Interface in the main menu/);
  assert.doesNotMatch(app, /Open Customer Interface<\/a>/);
});

test('V269 a deep link to a deleted tab lands on the surface that owns it, not a blank tab', () => {
  assert.match(app, /const SETTINGS_TABS_MOVED_TO_CUSTOMER_INTERFACE_V269=\['workspace','programme','fields','data'\];/);
  /* V296 retarget: the redirect now names the SECTION that absorbed each deleted tab, which is
     strictly more precise than the surface-level landing V269 asked for. */
  assert.match(app,
    /const SETTINGS_TAB_CUSTOMER_INTERFACE_VIEW_V296=\{workspace:'brand',programme:'programme',fields:'interface',data:'interface'\};/);
  assert.match(settings,
    /if\(SETTINGS_TABS_MOVED_TO_CUSTOMER_INTERFACE_V269\.includes\(requestedSettingsTab\)\)\s*\r?\n?\s*return nav\(`#\/customer-interface\/\$\{SETTINGS_TAB_CUSTOMER_INTERFACE_VIEW_V296\[requestedSettingsTab\]\}`\);/);
  // the remembered tab can no longer be one of the deleted ones, on any entry path
  assert.match(app, /let settingsActiveTab='modules';/);
  assert.match(settings, /if\(!\['modules','catalogue','team'\]\.includes\(settingsActiveTab\)\)settingsActiveTab='modules';/);
  assert.doesNotMatch(app, /href="#\/settings\?tab=workspace"/);
});

/* ----------------------------------------------------- (A2) it MOVED — one copy of everything */

test('V269 each moved panel is defined exactly once in the bundle', () => {
  for (const [what, marker] of [
    ['Workspace & brand markup', /function workspaceBrandPanelHtmlV259\(\)\{/g],
    ['Workspace & brand form', /id="bsave"/g],
    ['brand colour field', /<label for="bc">Brand colour/g],
    ['customer programme editor host', /id="customerProgrammeEditorV95"/g],
    ['Interface markup', /function customerInterfaceSectionsHtmlV243\(/g],
    ['sign-up card host', /id="signupWrap"/g],
    ['customer fields list', /id="cfList"/g],
    ['customer app actions', /id="businessCustomerCapabilities"/g],
  ]) assert.equal((app.match(marker) || []).length, 1, `${what} must exist exactly once`);
});

test('V269 each moved save handler is defined exactly once in the bundle', () => {
  for (const [what, marker] of [
    ['workspace save', /\$\('bsave'\)\.onclick=/g],
    ['workspace save wiring', /function wireWorkspaceBrandV259\(\)\{/g],
    ['customer field add', /\$\('cfAdd'\)\.onclick=/g],
    ['customer capabilities save', /function wireCustomerInterfaceV243\(/g],
    ['programme presentation editor', /async function loadCustomerProgrammePresentationEditorV95\(\)\{/g],
  ]) assert.equal((app.match(marker) || []).length, 1, `${what} must exist exactly once`);
});

test('V269 Settings no longer renders, loads or wires any of the moved forms', () => {
  for (const gone of [
    /id="bsave"/, /id="bru"/, /<label for="bc">/, /id="customerProgrammeEditorV95"/,
    /id="signupWrap"/, /id="businessCustomerCapabilities"/, /id="csvf"/, /id="cfAdd"/,
    /loadSignupConfig\(\)/, /loadCustomerCapabilitiesV223\(\)/, /client_field_definitions/,
  ]) assert.doesNotMatch(settings, gone, `Settings still carries ${gone}`);
  // the loader left with its host; only the explanatory comments still name these
  assert.doesNotMatch(settings, /^\s*loadCustomerProgrammePresentationEditorV95\(\);/m);
  assert.doesNotMatch(settings, /^\s*loadWorkspaceLogoEditorV96\(\);/m);
});

/* ------------------------------------------- (A3) the three named sections, in the drawn order */

test('V269 Customer Interface presents the three sections the owner named, in order', () => {
  const headings = [...customerInterface.matchAll(/customerInterfaceSectionHeadingV269\('[A-Za-z0-9]+','([^']+)'/g)]
    .map((m) => m[1]);
  /* V296 retarget: the same three sections, in the same order, are now the rail's sub-tabs.
     'Interface' was renamed 'Sign-up & fields' (its own hint's words) so the child row says what
     it holds, and the moved gift-card switch adds a fourth section after them. */
  /* V303 (owner 2026-08-13: "remove gift cards from the business UI entirely"): the fourth
     section V296 added is gone again, leaving exactly the three sections this test is named for. */
  assert.deepEqual(headings, ['Workspace & brand', 'Customer programme', 'Sign-up & fields']);
  // each heading immediately precedes the panel it names
  const order = [
    "customerInterfaceSectionHeadingV269('ciSectionBrandV269'",
    'workspaceBrandPanelHtmlV259()',
    "customerInterfaceSectionHeadingV269('ciSectionProgrammeV269'",
    'id="customerProgrammeEditorV95"',
    "customerInterfaceSectionHeadingV269('ciSectionInterfaceV269'",
    'customerInterfaceSectionsHtmlV243(',
    /* V303: the V296 Gift cards section and its switch left this page with the rest of the
       gift-card surface (owner: "remove gift cards from the business UI entirely"). */
  ];
  let cursor = -1;
  for (const marker of order) {
    const at = customerInterface.indexOf(marker, cursor + 1);
    assert.ok(at > cursor, `out of order: ${marker}`);
    cursor = at;
  }
});

test('V269 nothing already living in Customer Interface was lost to the new sections', () => {
  for (const kept of [
    /customerInterfacePreviewCardHtmlV243\(\)/, /wireCustomerInterfacePreviewV243\(\)/,
    /wireWorkspaceBrandV259\(\)/, /loadCustomerProgrammePresentationEditorV95\(\)/,
    /wireCustomerInterfaceV243\(\(\)=>customerInterfacePageV243\(hashParam\)\)/,
  ]) assert.match(customerInterface, kept);
});

/* --------------------------------------------------------------- (A4) access gating unchanged */

test('V269 the owner-only gate is exactly what it was, on both routes', () => {
  assert.match(app, /if\(pageKey==='settings'&&S\.myRole!=='owner'\)\{/);
  assert.match(app, /if\(pageKey==='customer-interface'&&S\.myRole!=='owner'\)\{/);
  assert.match(customerInterface, /const canEditCustomerInterface=S\.myRole==='owner';/);
  // the in-page check still guards every editable panel, and only the owner reads field defs
  assert.match(customerInterface, /\$\{canEditCustomerInterface\?`/);
  assert.match(customerInterface, /const \{data:fieldDefs,error:fieldDefsError\}=canEditCustomerInterface/);
  assert.match(customerInterface, /if\(!canEditCustomerInterface\)return;/);
  assert.match(app, /if\(S\.myRole==='owner'\)loadWorkspaceLogoEditorV96\(\);/);
});

/* ------------------------------------------------- (B1) the Appointments entry point + count */

test('V269 Appointments carries a Booking requests button gated on bookings READ access', () => {
  assert.match(appointments, /const canSeeBookingRequestsV269=canReadModule\('bookings'\);/);
  assert.match(appointments, /id="apptBookingRequestsV269"[^`]*Booking requests/);
  assert.match(appointments, /id="apptBookingRequestsCountV269"/);
  // it sits with Block time and New appointment in the page header
  assert.match(appointments, /const apptHeaderActions=`\$\{bookingRequestsActionV269\}\$\{canWrite\?/);
  assert.match(appointments, /id="openBlockTime"/);
  assert.match(appointments, /id="openAppointmentForm"/);
});

test('V269 the pending count counts only requests that can still be decided', () => {
  assert.match(appointments,
    /sb\.from\('booking_requests'\)\.select\('id',\{count:'exact',head:true\}\)\s*\.eq\('business_id',S\.biz\.id\)\.in\('status',\[\.\.\.STAFF_BOOKING_DECISION_STATUSES\]\)/);
  // one shared definition of "still decidable", so the badge cannot drift from the buttons
  assert.equal((app.match(/const STAFF_BOOKING_DECISION_STATUSES=new Set\(/g) || []).length, 1);
  assert.match(app, /const STAFF_BOOKING_DECISION_STATUSES=new Set\(\['new','pending','waitlisted'\]\);/);
});

test('V269 zero, unreadable and stale counts are all handled honestly', () => {
  assert.match(appointments, /if\(!isCurrent\(\)\)return;/);
  assert.match(appointments, /if\(!badge\?\.isConnected\)return;/);
  assert.match(appointments, /if\(error\)\{[\s\S]*?count unavailable[\s\S]*?return;\s*\}/);
  assert.match(appointments, /if\(!waiting\)\{[\s\S]*?none waiting[\s\S]*?return;\s*\}/);
  // a zero never renders as an empty badge
  assert.match(appointments, /badge\.textContent=String\(waiting\);badge\.hidden=false;/);
  assert.match(appointments, /id="apptBookingRequestsCountV269" hidden/);
});

test('V269 the button hands off to the one page that owns the decision', () => {
  assert.match(appointments, /bookingRequestsButtonV269\.onclick=\(\)=>nav\('#\/bookings'\);/);
  // Bookings opens on the requests tab, so the hand-off lands on the requests themselves
  assert.match(app, /tabs\.querySelector\('#bookingsTabRequests'\)\.onclick=\(\)=>setTab\('requests'\);/);
  /* V288 (audit A2 HIGH 3): RETARGETED, not deleted. The enhancement's last act is still to
     open a tab — but a realtime re-render must restore the tab the owner was actually on
     rather than always snapping back to Requests, so the literal 'requests' is now the
     fallback of that restore rather than an unconditional call. */
  assert.match(app, /setTab\(bookingsActiveTabV288==='settings'\?'settings':'requests'\);\n\}/);
});

/* --------------------------------- (B2) accept/decline: one path each, idempotent, gated */

test('V269 Appointments does not grow a second accept or decline path', () => {
  assert.doesNotMatch(appointments, /sb\.rpc\('staff_decide_booking_request_v73'/);
  assert.doesNotMatch(appointments, /convert_booking_request/);
  // the decision RPC is called from exactly the two surfaces that owned it before V269
  assert.equal((app.match(/sb\.rpc\('staff_decide_booking_request_v73'/g) || []).length, 2,
    'Bookings and Waitlist only');
});

test('V269 accept reuses the existing conversion RPC and decline is a recorded decision', () => {
  assert.match(bookings, /const \{data,error\}=await sb\.rpc\('staff_decide_booking_request_v73',\{\s*p_business:S\.biz\.id,p_request:id,p_decision:decision,p_branch:null\s*\}\)/);
  assert.match(bookings, /onclick="decideBookingRequestV73\('\$\{b\.id\}','confirm'\)"/);
  assert.match(bookings, /onclick="decideBookingRequestV73\('\$\{b\.id\}','decline'\)"/);
  // a declined request stays in the list with its status, so "did anyone answer me" is answerable
  assert.match(bookings, /sb\.from\('booking_requests'\)\.select\('\*, services\(name\)'\)/);
  assert.doesNotMatch(bookings, /from\('booking_requests'\)[^\n]*\.delete\(\)/,
    'a declined request must stay on the record, never be deleted');
});

test('V269 a double tap cannot produce two appointments', () => {
  // the browser refuses the second tap...
  assert.match(bookings, /if\(!authorized\|\|pendingDecisions\.has\(id\)\|\|!isCurrent\(\)\)return;/);
  assert.match(bookings, /pendingDecisions\.add\(id\);/);
  assert.match(bookings, /\.forEach\(button=>button\.disabled=true\);/);
  // ...and the RPC is idempotent regardless, so a replay is reported, not re-applied
  assert.match(app, /function bookingDecisionNotice\(result,decision\)\{/);
  assert.match(app, /replayed/);
});

test('V269 permission gating on the decision matches the role model, not an assumption', () => {
  /* Confirm creates an appointment; decline only closes a booking request.
     V288 (audit A2 HIGH 1): RETARGETED, not deleted. Both decisions are BOOKINGS rights now —
     the fnb and bar sectors are never entitled to the appointments module, so demanding it made
     confirmation impossible for the beachhead vertical while decline stayed available. */
  assert.match(bookings, /const canConvertBooking=canWriteModule\('bookings'\);/);
  assert.match(bookings, /const canDeclineBooking=canWriteModule\('bookings'\);/);
  assert.match(bookings, /const authorized=decision==='confirm'\?canConvertBooking:decision==='decline'\?canDeclineBooking:false;/);
});

test('V269 a slot that is no longer free is reported, never double-booked', () => {
  const notice = section('function bookingDecisionNotice(result,decision){', '/* V200 (owner:');
  // the RPC's own outcome word (scheduling_conflict, capacity_conflict, terminal_conflict, …) is
  // surfaced verbatim and marked NOT ok, so a refused confirm can never read as a success
  assert.match(notice, /const outcome=String\(result\?\.outcome\|\|'unknown'\);/);
  assert.match(notice, /return \{ok:false,text:`\$\{verb\} could not be applied \(\$\{outcome\.replaceAll\('_',' '\)\}\)\./);
  assert.match(notice, /if\(outcome==='replayed'\|\|result\?\.replayed===true\)return \{ok:true,text:`\$\{verb\} was already applied/);
});
