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
/* V325 (owner-authorized relocation, 2026-08-14 Customer Interface cosmetics brief): the
   overflow/auto-confirm booking rules moved out of bookingsPage into bookingRulesCardHtmlV325 /
   wireBookingRulesV325, rendered by Customer Interface's Appointment Setting step. */
const bookingRules = strip(app.slice(app.indexOf('function bookingRulesCardHtmlV325('),
  app.indexOf('function customerInterfacePreviewSideCardHtmlV325(')));

/* (1) "inventory change to Products" */
test('V223 the module is called Products in the nav, matching its own page', () => {
  assert.match(app, /inventory:\['inventory','Products'\]/);
  assert.doesNotMatch(app, /inventory:\['inventory','Inventory'\]/);
});

/* (2) "how can table bookings be present in a spa/salon?" */
test('nestly_v584 seating left Bookings entirely, and the rule that needs it did not', () => {
  /* V223/V235 gated the seating question so a spa was never offered a switch it could not
     truthfully use. Owner photo 13 goes further: "delete booking settings", and — asked directly
     what should happen to the seating switch, Tables / capacity and the CSV import inside it —
     "delete the tab and the contents". So Bookings no longer asks the question at all. */
  assert.doesNotMatch(bookings, /setTakesTablesV223/);
  assert.doesNotMatch(bookings, /Tables \/ capacity/);
  assert.doesNotMatch(bookings, /seatingSectorV235/);
  /* The one rule that genuinely depends on seating — "when you're full" — lives in Customer
     Interface -> Appointment Setting and is untouched, still behind its own sector gate. */
  assert.match(bookingRules, /\$\{seatsGuestsV235\?`<label for="setOverflow">When you're full<\/label>/);
  assert.match(bookingRules, /const seatingSectorV235=\['fnb','bar','other'\]\.includes\(String\(S\.biz\.industry\|\|''\)\.toLowerCase\(\)\);/);
  // And Bookings still points at where the rules live, rather than growing a second copy.
  assert.match(bookings, /Booking rules, opening hours and who customers may choose now live in <a href="#\/customer-interface\/appointment">/);
});

test('V223 customer app actions live with the other customer settings, not in Bookings', () => {
  assert.doesNotMatch(bookings, /businessCustomerCapabilities/);
  assert.doesNotMatch(bookings, /customer_capabilities_v89/);
  assert.doesNotMatch(bookings, /customerBookingEnabled/);
  // Moved whole: markup in the Customer interface tab, behaviour in a sibling loader.
  assert.match(app, /async function loadCustomerCapabilitiesV223\(\)\{/);
  /* V368: the sign-up QR left this page for the profile menu's dialog, so the capabilities
     loader no longer has it as a neighbour. The property this line protects — the switches load
     through their own loader on the page that shows them — is asserted directly. */
  assert.match(app, /loadCustomerCapabilitiesV223\(\);/);
  // settingsPage has no isCurrent(); the moved loader must use this page's own guard.
  const loader = app.slice(app.indexOf('async function loadCustomerCapabilitiesV223'),
    app.indexOf('function openBusinessQrModalV368'));
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
