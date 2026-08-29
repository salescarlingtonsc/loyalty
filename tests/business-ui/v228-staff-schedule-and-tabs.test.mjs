/* V228 — the last two annotations.
   (a) "staff schedule should not be in bookings - it should be in staff modules".
   (b) Settings: arrows from Workspace & brand / Customer programme / Customer interface onto
       one spot, captioned "Put new tab here · Customer Interface". */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const bookingsStart = app.indexOf('async function bookingsPage');
const bookings = app.slice(bookingsStart, app.indexOf('\nasync function ', bookingsStart + 1));
/* V325 (owner-authorized relocation, 2026-08-14 Customer Interface cosmetics brief): the shop
   opening-hours grid moved out of bookingsPage into wireBookingRulesV325, rendered by Customer
   Interface's Appointment Setting step. */
const bookingRulesStart = app.indexOf('function bookingRulesCardHtmlV325(');
const bookingRules = app.slice(bookingRulesStart, app.indexOf('function customerInterfacePreviewSideCardHtmlV325(', bookingRulesStart));

test('V228 Bookings no longer owns the staff rota', () => {
  // None of the rota markup, state or writes are left behind.
  for (const leftover of ['data-staff-member', 'data-staff-bookable', 'data-staff-rota',
    'staff_hours', 'customer_bookable', 'rotaByStaff']) {
    assert.doesNotMatch(bookings, new RegExp(leftover), `Bookings still references ${leftover}`);
  }
  /* V325: the shop's own opening hours moved from Bookings to Customer Interface's Appointment
     Setting step (bookingRulesCardHtmlV325 / wireBookingRulesV325) along with the rest of the
     booking rules — same markup and handlers, just relocated. Bookings no longer references
     branch_hours or the shop hour rows at all. */
  assert.doesNotMatch(bookings, /branch_hours/);
  assert.doesNotMatch(bookings, /v183HourRowMarkup\('shop'/);
  assert.match(bookingRules, /branch_hours/);
  assert.match(bookingRules, /v183HourRowMarkup\('shop'/);
  // And it no longer claims to load something it does not.
  assert.match(bookingRules, /Opening hours could not be loaded/);
  assert.doesNotMatch(bookingRules, /Opening hours and team availability could not be loaded/);
});

test('V228 the rota renders and saves from Staff Members', () => {
  // V260: the owner struck out the whole "Working hours" card at the top of the Staff list
  // tab (heading, explanatory line, "Loading working hours…" state, and Save button). It has
  // no other home in the app (verified: no per-staff row exposes it), so the handlers stay
  // defined rather than deleted — only the markup and its call site were removed. These two
  // assertions that used to pin the visible card are now assertions that it is GONE.
  assert.match(app, /function staffRotaSectionMarkupV228\(team,rotaByStaff\)\{/);
  assert.doesNotMatch(app, /id="staffRotaCardV228"/);
  assert.doesNotMatch(app, /<b>Working hours<\/b>/);
  assert.doesNotMatch(app, /loadTeam\(\);\s*\n\s*loadStaffRotaV228\(\);/);
  const save = app.slice(app.indexOf('async function saveStaffRotaV228'), app.indexOf('async function loadTeam'));
  // It writes exactly what the Bookings version wrote, so an existing rota is unchanged.
  assert.match(save, /sb\.from\('staff'\)\.update\(\{customer_bookable:member\.customer_bookable\}\)/);
  assert.match(save, /sb\.from\('staff_hours'\)\.upsert\([\s\S]*\{onConflict:'staff_id,weekday'\}\)/);
  // The guard that stops an empty rota silently reverting someone to shop hours survives.
  assert.match(save, /works their own hours but has no open day/);
  // Unticking still clears the rota, which is what returns them to shop hours. nestly_v600: this
  // screen writes hours only — a repeating day off is set in Block time, its single home.
  assert.match(save, /:\[sb\.from\('staff_hours'\)\.delete\(\)\.eq\('business_id',S\.biz\.id\)\.eq\('staff_id',rota\.staffId\)\]/);
});

test('V228 the shared weekday row is defined once, not duplicated', () => {
  // Two copies would drift apart; that is why it was lifted rather than copied.
  assert.equal((app.match(/const v183HourRowMarkup=/g) || []).length, 1);
  assert.equal((app.match(/const V183_DAYS=/g) || []).length, 1);
});

/* V269 SUPERSEDES the V228 ordering: the owner deleted the three customer-facing tabs from
   Settings altogether, so "they come first" no longer has anything to order. What survives is
   that Settings is now purely the operations tabs. */
test('V269 Settings keeps only the operations tabs', () => {
  const start = app.indexOf('class="settings-tabs" data-workspace-i18n');
  const strip = app.slice(start, app.indexOf('</div>', app.indexOf('settab-team', start)));
  const order = [...strip.matchAll(/data-settab="([a-z]+)"/g)].map((m) => m[1]);
  assert.deepEqual(order, ['modules', 'catalogue', 'team']);
});
