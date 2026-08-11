/* V246 — two owner reports from the Cafe2U (F&B) demo tenant.
   "why cafe/F&B have appointment module? appointment is for a staff to serve the customer for
   a service. cafe is about bookings / table bookings and reservation - with a waitlist"
   "why pressing back will log me out of the app? i thought there is local cache?" — the
   session was never lost: Back lands on '#/', the customer entry, and a signed-in
   business-only user has no customer profile, so the surface fell through to the customer
   sign-in screen, which reads exactly like being logged out. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

test('V246 an F&B business does not advertise Appointments in the rail', () => {
  /* V276 retarget: the rule survives, it just stopped being a bare string comparison. V276
     turned it into a named sector set so a bar — which serves the way a cafe does — inherits it.
     The assertion still proves what V246 proved: 'fnb' hides Appointments in the rail. */
  assert.match(app, /const sectorHidesAppointmentsV246=sectorHidesAppointmentsV276\(\);/);
  assert.match(app, /const SEATED_SECTORS_WITHOUT_APPOINTMENTS_V276=new Set\(\['fnb','bar'\]\);/);
  assert.match(app, /\(m==='appointments'&&!sectorHidesAppointmentsV246&&enabled\.includes\(m\)\)/);
  // Every other module keeps its exact old rule.
  assert.match(app, /\(m!=='waitlist'&&m!=='appointments'&&enabled\.includes\(m\)\)/);
});

test('V246 hiding is nav-level only — the route survives for history and deep links', () => {
  // No route guard was added: the only appointments route guards are the pre-existing ones.
  const routeFn = app.slice(app.indexOf('async function route(){'), app.indexOf('function passwordControlHtml('));
  assert.doesNotMatch(routeFn, /sectorHidesAppointmentsV246/,
    'an F&B tenant with historical appointments or a Customer 360 hand-off must not be stranded');
});

test('V246 the serving model per sector stays coherent', () => {
  // Bookings + Waitlist remain available to F&B (waitlist still rides on bookings, per V223),
  // and the table-seating settings stay sector-gated from V235.
  assert.match(app, /\(m==='waitlist'&&enabled\.includes\('waitlist'\)&&enabled\.includes\('bookings'\)\)/);
  assert.match(app, /seatingSectorV235/);
});

test('V246 a signed-in business user landing on the customer entry goes to the workspace', () => {
  const reg = app.slice(app.indexOf('async function renderCustomerRegistration('), app.indexOf('const CUSTOMER_LOCALES'));
  // Only when there is no customer profile, and only when a staff persona exists.
  assert.match(reg, /if\(profile\?\.profile===null\|\|profile\?\.profile===undefined\)\{/);
  assert.match(reg, /const personasResultV246=await sb\.rpc\('get_my_personas'\);/);
  assert.match(reg, /if\(\(personasResultV246\.data\?\.staff\|\|\[\]\)\.length\)\{nav\('#\/dashboard'\);return;\}/);
  // The bounce is stale-guarded like every other await on this surface.
  const bounce = reg.slice(reg.indexOf('const personasResultV246'));
  assert.ok(bounce.indexOf('if(!isRouteCurrent())return;') < bounce.indexOf("nav('#/dashboard')"));
  // A user with a customer profile keeps the existing wallet path; one with neither still
  // reaches sign-in, which is then the truth.
  assert.match(reg, /if\(profile\?\.profile!==null&&profile\?\.profile!==undefined\)\{/);
  assert.match(reg, /return renderCustomerPasswordSignIn\(isRouteCurrent\);/);
});
