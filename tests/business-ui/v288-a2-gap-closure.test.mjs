/* V288 — audit A2 gap closure (Appointments / Bookings / Waitlist / Bottles / Programmes).
   Each test below pins one finding so it cannot silently come back. The four that matter most:
   an fnb/bar tenant CAN confirm a booking request, the router keeps query strings, an expired
   bottle has transitions, and the declarative tier-window save cannot run off a failed read. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
/* Tests that grep application code read the CONCATENATION of index.html + app.js (AGENTS.md). */
const app = readFileSync(join(root, 'app', 'index.html'), 'utf8')
  + readFileSync(join(root, 'app', 'app.js'), 'utf8');
const migration = readFileSync(
  join(root, 'db', 'migrations', '20260812_nestly_v288_a2_gap_closure.sql'), 'utf8');
const suite = readFileSync(join(root, 'db', 'tests', 'v288_a2_gap_closure.sql'), 'utf8');

const between = (from, to) => {
  const start = app.indexOf(from);
  assert.notEqual(start, -1, `anchor not found: ${from}`);
  const end = app.indexOf(to, start);
  assert.notEqual(end, -1, `anchor not found: ${to}`);
  return app.slice(start, end);
};

const bookingsPage = between('async function bookingsPage(){', '/* ---------- grow recommender');
const waitlistPage = between('async function waitlistPage(){', 'function rowHtml(w,pos){');
const appointmentsPage = between('async function appointmentsPage(){',
  '/* ---------- waitlist (conversion queue) ----------');
const bottleSetupPage = between('async function bottleSetupPageV275(){', 'async function bottlesPage(){');
const bottlesPage = between('async function bottlesPage(){', '/* The event log speaks');

/* ------------------------------------------------------------------ HIGH 1 */

test('HIGH 1 — an fnb/bar tenant can CONFIRM a booking request, not only decline it', () => {
  /* The request lives in Bookings, so Bookings write is the right that decides it. */
  assert.match(bookingsPage, /const canConvertBooking=canWriteModule\('bookings'\);/);
  assert.match(bookingsPage, /const canDeclineBooking=canWriteModule\('bookings'\);/);
  assert.doesNotMatch(bookingsPage, /const canConvertBooking=canWriteModule\('appointments'\)/);
  /* Same ruling on the waitlist row that carries a booking request. */
  assert.match(waitlistPage, /const canConfirmLinked=canWriteModule\('bookings'\);/);
  assert.doesNotMatch(waitlistPage, /const canConfirmLinked=canWriteModule\('appointments'\)/);
});

test('HIGH 1 — the server stops demanding a module the seated sectors can never hold', () => {
  /* app.effective_platform_module_mode_v94 resolves an un-entitled module to 'disabled' by
     SECTOR, so an unconditional appointments requirement was unsatisfiable for everyone in an
     fnb/bar tenant — the owner included. */
  assert.match(migration, /create or replace function app\.business_has_appointments_module_v288/);
  assert.match(migration, /effective_platform_module_mode_v94\(p_business, p_branch, 'appointments'\)/);
  /* Both the v94 wrapper and the base carry the gate, so both are spliced. */
  assert.match(migration, /staff_decide_booking_request_v73\(uuid,uuid,text,uuid\)/);
  assert.match(migration, /staff_decide_booking_request_v73_v94_base\(uuid,uuid,text,uuid\)/);
  /* Every splice verifies against the DEPLOYED definition and refuses to guess. */
  assert.equal((migration.match(/refusing to guess|found %/g) || []).length >= 2, true);
  /* The bookings boundary is never dropped — the splice asserts it survived. */
  assert.match(migration, /the bookings gate was lost/);
  /* And the appointments boundary still applies wherever the sector HAS appointments. */
  assert.match(migration, /business_has_appointments_module_v288\(p_business,v_branch\)/);
});

test('HIGH 1 — the rollback suite proves the confirm end to end for a bar tenant', () => {
  /* V288 courier correction C1: the dependency guard force-adds appointments wherever bookings
     exists, so the original enabled_modules flip was impossible; the corrected suite uses the
     real bar tenant plus a platform module override — pin that mechanism instead. */
  assert.match(suite, /platform_module_overrides_v94/);
  assert.doesNotMatch(suite.slice(suite.indexOf("enabled_modules = array['dashboard'")),
    /^[^;]*'appointments'/);
  /* V288 courier correction: the corrected suite drives the same RPC with its full real
     signature rather than the shorthand the pre-run pin guessed at. */
  assert.match(suite, /staff_decide_booking_request/);
  assert.match(suite, /'confirm'/);
    assert.match(suite, /from public\.appointments/); // the created record is asserted to land
});

/* ------------------------------------------------------------------ HIGH 2 */

test('HIGH 2 — the Bookings shell is marked, never inferred from #cp\'s ancestors', () => {
  assert.match(bookingsPage, /data-bookings-shell="head"/);
  assert.match(bookingsPage, /data-bookings-shell="portal"/);
  assert.match(bookingsPage, /data-bookings-shell="changes"/);
  const enhance = between('function enhanceBookingsTabsV195(root){', 'const V183_DAYS=');
  assert.match(enhance, /child\.hasAttribute\('data-bookings-shell'\)/);
  /* The structural guess that returned null is gone. */
  assert.doesNotMatch(enhance, /querySelector\('#cp'\)\?\.closest/);
});

/* ------------------------------------------------------------------ HIGH 3 */

test('HIGH 3 — the tabs survive a realtime re-render, and keep the active tab', () => {
  const enhance = between('function enhanceBookingsTabsV195(root){', 'const V183_DAYS=');
  /* The guard is a per-render token, not a sticky '1' that outlives innerHTML. */
  assert.match(enhance, /root\.dataset\.bookingsTabsV195!==String\(bookingsShellTokenV288\)/);
  assert.doesNotMatch(enhance, /root\.dataset\.bookingsTabsV195==='1'/);
  assert.match(enhance, /bookingsActiveTabV288=showRequests\?'requests':'settings'/);
  assert.match(enhance, /setTab\(bookingsActiveTabV288==='settings'\?'settings':'requests'\)/);
  assert.match(bookingsPage, /bookingsShellTokenV288\+=1;/);
  assert.match(bookingsPage, /routeMain\.dataset\.bookingsTabsV195=String\(bookingsShellTokenV288\)/);
});

test('HIGH 3 — an auto-refresh never re-renders under a cursor', () => {
  const refresh = between('function autoRefreshIfRelevant(){', 'function ensureRealtimeChannel(){');
  assert.match(refresh, /document\?\.activeElement/);
  assert.match(refresh, /\['INPUT','SELECT','TEXTAREA'\]\.includes\(focused\.tagName\)/);
  assert.match(refresh, /if\(editing&&M\(\)\?\.contains\(focused\)\)return;/);
});

/* ------------------------------------------------------------------ HIGH 4 */

test('HIGH 4 — the router keeps query strings instead of dropping the route', () => {
  const router = between('async function route(){', 'if(h.startsWith(\'#/workspace/\')){');
  assert.match(router, /routeQueryParamsV288=new URLSearchParams/);
  assert.match(router, /h=String\(h\)\.split\('\?'\)\[0\];/);
  assert.match(app, /function routeParamV288\(name\)\{/);
  /* The page key is computed from the stripped hash, so '#/appointments?view=list' resolves. */
  assert.match(app, /const page=workspacePage\?\[workspacePage\]/);
});

test('HIGH 4 — the deep link the Dashboard already publishes actually opens the List view', () => {
  assert.match(app, /href="#\/appointments\?view=list&preset=today"/);
  assert.match(appointmentsPage, /const applyAppointmentPresetV288=\(preset,\{reload=true\}=\{\}\)=>\{/);
  assert.match(appointmentsPage, /applyAppointmentPresetV288\(routeParamV288\('preset'\),\{reload:false\}\)/);
  assert.match(appointmentsPage, /routeParamV288\('view'\)==='list'\)setCalendarView\('list'\)/);
});

/* ------------------------------------------------------------------ HIGH 5 */

test('HIGH 5 — the List view shares the calendar\'s error card and retry', () => {
  assert.match(appointmentsPage, /function renderAppointmentLoadErrorV288\(error,retry\)\{/);
  assert.match(appointmentsPage, /const loadAppointmentsGuardedV288=\(\)=>loadCalendar\(\)\.catch\(/);
  /* loadList no longer throws into an unhandled rejection. */
  assert.doesNotMatch(appointmentsPage, /if\(!stillCurrent\(\)\)return;if\(error\)throw error;/);
  /* every caller routes through the one guarded entry point */
  assert.doesNotMatch(appointmentsPage, /loadList\(\)\.catch\(fail\)/);
});

/* ------------------------------------------------------------------ HIGH 6 */

test('HIGH 6 — a failed tier read disables the DECLARATIVE tier-window save', () => {
  assert.match(bottleSetupPage, /if\(extraUnavailableV278\)\{[\s\S]*?blockedSave\.disabled=true;/);
  assert.match(bottleSetupPage, /saving now would clear every tier/);
  /* And the handler refuses too, so a stale DOM cannot re-arm it. */
  const saveHandler = bottleSetupPage.slice(bottleSetupPage.indexOf("$('bkTierSave').onclick="));
  assert.match(saveHandler, /if\(extraUnavailableV278\)\{/);
  assert.match(saveHandler, /Reload the page before saving/);
});

/* ------------------------------------------------------------------ MEDIUM 7 */

test('MEDIUM 7 — a cancelled appointment no longer occupies a calendar lane', () => {
  assert.match(appointmentsPage,
    /items\.forEach\(item=>\(inactiveAppointmentStatuses\.has\(String\(item\.status\|\|''\)\.toLowerCase\(\)\)\?inactive:live\)\.push\(item\)\)/);
  assert.match(appointmentsPage, /function layoutActiveCalendarDayV288\(items\)\{/);
  assert.match(appointmentsPage, /lane:0,laneCount:1,inactiveV288:true/);
  /* Both grids carry the treatment, and the CSS exists. */
  assert.match(appointmentsPage, /class="day-timeline-event\$\{inactiveV288\?' appointment-inactive-v288':''\}"/);
  assert.match(appointmentsPage, /class="calendar-event\$\{inactiveV288\?' appointment-inactive-v288':''\}"/);
  assert.match(app, /\.calendar-event\.appointment-inactive-v288/);
});

/* ------------------------------------------------------------------ MEDIUM 8 */

test('MEDIUM 8 — sector-hiding is one predicate on every appointment front door', () => {
  const dashboard = between('<section class="card dashboard-schedule-glance"', 'dashboard-schedule-controls-v252');
  assert.match(dashboard, /sectorHidesAppointmentsV276\(\)/);
  assert.match(dashboard, /href="#\/bookings">Open bookings/);
  assert.match(app, /const canBookAppt=canWriteModule\('appointments'\)&&!sectorHidesAppointmentsV276\(\);/);
  assert.match(waitlistPage, /const seatedWithoutAppointmentsV288=sectorHidesAppointmentsV276\(\);/);
  assert.match(waitlistPage, /seatedWithoutAppointmentsV288\?canWriteModule\('bookings'\):canWriteModule\('appointments'\)/);
  assert.match(waitlistPage, /if\(seatedWithoutAppointmentsV288\)\{[\s\S]*?nav\('#\/bookings'\);return;/);
});

/* ------------------------------------------------------------------ MEDIUM 11/12 */

test('MEDIUM 11 — archiving a reward asks first, with an explicit summary', () => {
  assert.match(app, /function confirmDeliberateV288\(\{title,summaryHtml=''/);
  assert.match(app, /title:'Archive this reward\?'/);
  assert.match(app, /acknowledgement:'I understand customers will no longer see this reward\.'/);
});

test('MEDIUM 12 — the tier ✕ became an explicit Pause, with a confirm and a toast', () => {
  assert.match(app, /class="btn ghost sm trDel"[^>]*>\s*<span data-workspace-i18n>Pause<\/span>/);
  assert.doesNotMatch(app, /class="btn ghost sm trDel" aria-label="Pause tier"/);
  assert.match(app, /title:'Pause this tier\?'/);
  assert.match(app, /Pause, not delete/);
  assert.match(app, /paused \\u2014 nothing was deleted|paused — nothing was deleted/);
});

/* ------------------------------------------------------------------ MEDIUM 14/15 */

test('MEDIUM 14 — an expired bottle gets Extend, Edit expiry and an honest Remove', () => {
  assert.match(bottlesPage, /const expiredV288=String\(bottle\.status\|\|''\)==='expired';/);
  assert.match(bottlesPage, /const actionableV288=live\|\|expiredV288;/);
  assert.match(bottlesPage, /\$\{mayWrite&&actionableV288\?/);
  assert.match(bottlesPage, /if\(!\(mayWrite&&actionableV288\)\)return;/);
  /* Extend and Edit expiry are unconditional inside the block; Retrieved is live-only. */
  assert.match(bottlesPage, /<button type="button" class="btn ghost sm" data-extend/);
  assert.match(bottlesPage, /<button type="button" class="btn ghost sm" data-expiry/);
  assert.match(bottlesPage, /\$\{live\?`<button type="button" class="btn ghost sm" data-retrieve/);
  /* Remove is drawn for both, and is explicitly NOT a retrieval. */
  assert.match(bottlesPage, /data-remove-v288/);
  assert.match(bottlesPage, /sb\.rpc\('remove_bottle_v288'/);
  assert.match(bottlesPage, /I understand the customer did not collect this bottle\./);
});

test('MEDIUM 14 — the server has the exit, keeps retrieved terminal, and gates the bar first', () => {
  assert.match(migration, /create or replace function public\.remove_bottle_v288\(/);
  const body = migration.slice(migration.indexOf('create or replace function public.remove_bottle_v288('));
  /* The bar gate is the FIRST statement, as every function in this module orders it. */
  assert.match(body, /begin\n  -- The bar gate is FIRST[\s\S]*?perform app\.require_bar_business_v275\(p_business\);/);
  assert.match(body, /perform app\.require_bar_staff_v275\(p_business, true\);/);
  /* Removable from every state where the bar still holds the bottle, expired included. */
  assert.match(body, /not in \('stored', 'called', 'at_table', 'expired'\)/);
  assert.match(body, /'to', 'removed'/);
  /* app.bar_status_transition_allowed_v279 is untouched: retrieved stays a one-way door. */
  assert.doesNotMatch(migration, /create or replace function app\.bar_status_transition_allowed/);
  /* Idempotent, like every other write in this module. */
  assert.match(body, /app\.bar_bottle_replayed_v275\(p_business, v_key\)/);
});

test('MEDIUM 15 — the catalogue row and the shelf list can be corrected', () => {
  /* The catalogue row now edits name and price, and sends them. */
  assert.match(bottleSetupPage, /data-bottle-name="\$\{index\}"/);
  assert.match(bottleSetupPage, /data-bottle-price="\$\{index\}"/);
  assert.match(bottleSetupPage, /sb\.rpc\('bar_save_bottle_product_v288',\{[\s\S]*?p_name:editedName,p_size_ml:size,p_price_cents:priceCents\}/);
  /* v278's update branch dropped them; v288's does not. */
  assert.match(migration, /create or replace function public\.bar_save_bottle_product_v288\(/);
  assert.match(migration, /name = coalesce\(v_name, product\.name\)/);
  assert.match(migration, /retail_price_cents = coalesce\(p_price_cents, product\.retail_price_cents\)/);
  /* The Add path deliberately stays on v278, which already worked. */
  assert.match(bottleSetupPage, /sb\.rpc\('bar_save_bottle_product_v278'/);
  /* Shelves are renameable in place, which the save RPC has always supported by id. */
  assert.match(bottleSetupPage, /data-location-name="\$\{index\}"/);
  assert.match(bottleSetupPage, /Every storage place needs a name/);
});

/* ------------------------------------------------------------------ MEDIUM 18/19 */

test('MEDIUM 18 — Customer Interface paints a loading state before it reads', () => {
  const page = between('async function customerInterfacePageV243(){', 'phone country-code picker');
  assert.match(page, /customerInterfaceHostV288[\s\S]*?CUI\.loadingState\(\{/);
  assert.equal(page.indexOf('CUI.loadingState({') < page.indexOf('client_field_definitions'), true);
});

test('MEDIUM 19 — a Bookings load failure is recoverable in place, not an eternal spinner', () => {
  assert.match(bookingsPage, /Booking requests unavailable/);
  assert.match(bookingsPage, /id="bookingListRetryV288"/);
  assert.match(bookingsPage, /id="changeRequestRetryV288"/);
  /* The old toast-and-leave-Loading path is gone from both loaders. */
  assert.doesNotMatch(bookingsPage, /if\(error\) return fail\(error\);\n    const list=\$\('blist'\)/);
});

/* ------------------------------------------------------------------ LOW 22/23 */

test('LOW 22 — publishing is deliberate without requiring English literacy', () => {
  assert.doesNotMatch(app, /placeholder="PUBLISH"/);
  assert.doesNotMatch(app, /!=='PUBLISH'/);
  assert.match(app, /\$\('growPubType'\)\.onchange=event=>\{\$\('growPubConfirm'\)\.disabled=event\.target\.checked!==true\}/);
  assert.match(app, /\$\('studioPubConfirm'\)\.disabled=e\.target\.checked!==true/);
  /* The summary of what changes is still shown above the acknowledgement. */
  assert.match(app, /I have read the changes above and want customers to get them now\./);
});

test('LOW 23 — raw database statuses do not reach the screen', () => {
  assert.match(app, /const STATUS_LABELS_V288=Object\.freeze\(\{/);
  assert.match(app, /function statusLabelV288\(status\)\{/);
  assert.match(bookingsPage, /\$\{esc\(statusLabelV288\(b\.status\)\)\}/);
  assert.match(appointmentsPage, /\$\{esc\(statusLabelV288\(a\.status\)\)\}/);
  assert.doesNotMatch(appointmentsPage, /esc\(a\.status\.replace\('_',' '\)\)/);
  assert.doesNotMatch(bookingsPage, /'no'\}">\$\{esc\(b\.status\)\}/);
});
