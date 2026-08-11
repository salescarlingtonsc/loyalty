/* V223 — the owner's module-separation batch. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/<!--[\s\S]*?-->/g, ' ');
const bookings = strip(app.slice(app.indexOf('async function bookingsPage'),
  app.indexOf('\nasync function ', app.indexOf('async function bookingsPage') + 1)));

/* (1) "inventory change to Products" */
test('V223 the module is called Products in the nav, matching its own page', () => {
  assert.match(app, /inventory:\['inventory','Products'\]/);
  assert.doesNotMatch(app, /inventory:\['inventory','Inventory'\]/);
});

/* (2) "how can table bookings be present in a spa/salon?" */
test('V223 seating controls appear only for a business that seats guests', () => {
  // V235: the controls are behind seatsGuestsV235 — the V223 flag AND a sector that seats.
  assert.match(bookings, /\$\{seatsGuestsV235\?`<div class="row"><b>Tables \/ capacity<\/b>/);
  assert.match(bookings, /\$\{seatsGuestsV235\?`<label>When you're full<\/label>/);
  assert.match(bookings, /const seatsGuestsV235=seatingSectorV235&&S\.biz\.takes_table_reservations===true;/);
  /* V235 (owner: "how can a spa have table seating at all"): the QUESTION itself is sector-gated,
     so an appointment business is never offered a switch it can never truthfully turn on. */
  /* V276 retarget: 'bar' joined the seated sectors — the copy under the switch already named a
     bar, but the list did not, so the one sector it names by hand never saw the control. The
     gating shape this test exists to pin is unchanged. */
  assert.match(bookings, /const seatingSectorV235=\['fnb','bar','other'\]\.includes\(String\(S\.biz\.industry\|\|''\)\.toLowerCase\(\)\);/);
  assert.match(bookings, /\$\{seatingSectorV235\?`<label[^`]*id="setTakesTablesV223"/s);
  // The owner can turn it on themselves.
  assert.match(bookings, /id="setTakesTablesV223"/);
  assert.match(bookings, /We seat guests at tables/);
  assert.match(bookings, /Leave it off for appointment work like a spa or salon/);
  // Handlers must not assume elements that may not be rendered.
  assert.match(bookings, /if\(\$\('tblAdd'\)\)\$\('tblAdd'\)\.onclick/);
  assert.match(bookings, /if\(!\$\('capBody'\)\)return;/);
  assert.match(bookings, /const overflow=\$\('setOverflow'\)\?\$\('setOverflow'\)\.value:null;/);
  assert.match(bookings, /const autoConfirm=\$\('setAutoConfirm'\)\?\$\('setAutoConfirm'\)\.checked:null;/);
  // A null must not be mirrored into local state — the server keeps the stored value.
  assert.match(bookings, /if\(overflow!==null\)S\.biz\.booking_overflow=overflow;/);
  assert.match(bookings, /if\(autoConfirm!==null\)S\.biz\.booking_auto_confirm=autoConfirm;/);
  // Flipping the switch changes which controls belong on the page, so it redraws.
  assert.match(bookings, /if\(seatingChanged\)bookingsPage\(\)/);
  assert.match(bookings, /p_takes_table_reservations:takesTables/);
});

/* (4) "customer app settings should not be in bookings" */
test('V223 customer app actions live with the other customer settings, not in Bookings', () => {
  assert.doesNotMatch(bookings, /businessCustomerCapabilities/);
  assert.doesNotMatch(bookings, /customer_capabilities_v89/);
  assert.doesNotMatch(bookings, /customerBookingEnabled/);
  // Moved whole: markup in the Customer interface tab, behaviour in a sibling loader.
  assert.match(app, /async function loadCustomerCapabilitiesV223\(\)\{/);
  assert.match(app, /loadSignupConfig\(\);\s*\n\s*loadCustomerCapabilitiesV223\(\);/);
  // settingsPage has no isCurrent(); the moved loader must use this page's own guard.
  const loader = app.slice(app.indexOf('async function loadCustomerCapabilitiesV223'),
    app.indexOf('async function loadSignupConfig'));
  assert.doesNotMatch(loader, /isCurrent\(\)/);
  assert.match(loader, /\$\('businessCustomerCapabilities'\)\?\.isConnected/);
  assert.match(loader, /business_set_customer_capabilities_v89/);
});

/* (5) "waitlist is tagged to bookings (so disable / enable together)" */
test('V223 Waitlist travels with Bookings, in the nav and at the route', () => {
  const nav = app.slice(app.indexOf('const navModuleVisible='), app.indexOf('const visGroups='));
  assert.match(nav, /\|\|\(m==='waitlist'&&enabled\.includes\('waitlist'\)&&enabled\.includes\('bookings'\)\)/);
  /* V246: appointments joined waitlist as a specially-gated module — hidden for the fnb
     sector. The waitlist-rides-on-bookings rule this test protects is unchanged. */
  assert.match(nav, /\|\|\(m!=='waitlist'&&m!=='appointments'&&enabled\.includes\(m\)\)/);
  // Hiding a link is not a guard — the typed hash is refused too.
  assert.match(app, /if\(pageKey==='waitlist'&&!canReadModule\('bookings'\)\)\{/);
  assert.match(app, /Waitlist works with Bookings\. Turn on Bookings first\./);
});
