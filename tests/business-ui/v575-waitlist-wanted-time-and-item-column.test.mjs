/* nestly_v575 — two owner marks.
   1. Sales & refunds: the Item column moves between Record status and Gross.
   2. Waitlist: the free-text "Preferred window" becomes a real date and time, so Book pushes
      straight into an appointment with only the team member left to choose. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appJs = await readFile(path.join(root, 'app/app.js'), 'utf8');
const section = (from, to) => {
  const a = appJs.indexOf(from); assert.ok(a > -1, `missing: ${from}`);
  const b = appJs.indexOf(to, a); assert.ok(b > a, `missing: ${to}`);
  return appJs.slice(a, b);
};

test('v575 the sales Item column sits between Record status and Gross', () => {
  const header = section('<tr><th>When</th><th>Customer</th>', '</tr>');
  const order = [...header.matchAll(/<th[^>]*>([^<]*)<\/th>/g)].map(m => m[1].trim());
  assert.deepEqual(order.slice(0, 7),
    ['When', 'Customer', 'Team member', 'Record status', 'Item', 'Gross', 'Net']);
  /* The BODY has to move with the header or every row is shifted one column. */
  const body = section('<tr><th>When</th><th>Customer</th>', '</table></div>');
  const itemAt = body.indexOf('salesItemCellV571(s)');
  const statusAt = body.indexOf('sales-audit-details');
  const grossAt = body.indexOf('money(s.amount_cents)');
  assert.ok(statusAt > -1 && itemAt > statusAt, 'Item comes after Record status');
  assert.ok(grossAt > itemAt, 'Item comes before Gross');
});

test('v575 the walk-in form records an instant, not a phrase', () => {
  const page = section('async function waitlistPage()', 'async function inventoryPage');
  assert.match(page, /<input type="datetime-local" id="ww">/, 'the wanted time is a real control');
  assert.match(page, /preferred_at:sgIso\(\$\('ww'\)\.value\)\|\|null/,
    'it is stored as an instant anchored to Singapore time');
  assert.doesNotMatch(page, /placeholder="e\.g\. weekday eve"/, 'the free-text window is gone');
});

test('v575 Book hands the appointment its date, time and service', () => {
  const page = section('window.wlBook=async id=>', 'window.wlCalled=');
  assert.match(page, /pendingApptPrefillV575=\{/);
  assert.match(page, /date:wantedV575\?wantedV575\.slice\(0,10\):''/);
  assert.match(page, /time:wantedV575\?wantedV575\.slice\(11,16\):''/);
  assert.match(page, /serviceId:row\?\.service_id\|\|''/);
  const appts = section('const apptPrefillClient=pendingApptClientId', '$(\'appointmentCustomerSearch\').oninput');
  assert.match(appts, /openNewAppointmentForm\(\{\s*date:apptPrefillV575\?\.date\|\|todaySg,\s*time:apptPrefillV575\?\.time\|\|'',\s*serviceId:apptPrefillV575\?\.serviceId\|\|''\s*\}\)/,
    'the form opens with all three filled');
  assert.match(appts, /if\(apptPrefillClient\|\|apptPrefillV575\)\{/,
    'a walk-in with no customer record still opens a prefilled form');
});

test('v575 a legacy row keeps its free text and opens an empty picker', () => {
  const src = section('function waitlistWantedTextV575(', 'function waitlistTodaySummary(');
  const { waitlistWantedTextV575, waitlistWantedInputValueV575 } = vm.runInNewContext(
    `${src}; ({waitlistWantedTextV575, waitlistWantedInputValueV575})`,
    { sgt: iso => new Date(new Date(iso).getTime() + 8 * 3600000).toISOString().slice(0, 16).replace('T', ' ') });

  const legacy = { preferred: 'weekday eve', preferred_at: null };
  assert.equal(waitlistWantedTextV575(legacy), 'weekday eve', 'the old note is still printed');
  assert.equal(waitlistWantedInputValueV575(legacy), '',
    'and no date is invented out of a phrase');

  const dated = { preferred: null, preferred_at: '2026-08-28T02:30:00.000Z' };
  assert.equal(waitlistWantedTextV575(dated), '2026-08-28 10:30', 'shown in Singapore time');
  assert.equal(waitlistWantedInputValueV575(dated), '2026-08-28T10:30', 'and round-trips into the picker');
});
