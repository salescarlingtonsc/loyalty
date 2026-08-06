import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

test('an unsold package version can be renamed or deleted', () => {
  // Owner: "i should be able to edit or delete". The freeze protects a customer who bought the
  // version — but both of this firm's versions had zero purchases, so it guarded nothing.
  assert.match(app, /data-package-rename=/);
  assert.match(app, /data-package-delete=/);
  assert.match(app, /Not sold to anyone yet, so it can still be renamed or deleted/);
});

test('a sold version keeps its freeze and says who it protects', () => {
  assert.match(app, /Sold to \$\{packagePurchaseCount\[p\.id\]\} customer/);
  assert.match(app, /create a new version to change anything/);
  // the count comes from the real FK, not a name/version snapshot guess
  assert.match(app, /from\('client_packages'\)\.select\('plan_id'/);
  assert.match(app, /if\(row\?\.plan_id\)tally\[row\.plan_id\]/);
});

test('writes go through the RPC, because package_plans is read-only to the browser', () => {
  assert.match(app, /business_manage_package_plan_v193/);
  assert.ok(!/from\('package_plans'\)\.(update|delete)\(/.test(app),
    'a direct write would silently affect zero rows under SELECT-only RLS');
  const i = app.indexOf('data-package-delete]');
  assert.match(app.slice(i, i + 700), /confirm\(/, 'deletion must be confirmed');
});

test('the appointment list filters share one baseline', () => {
  // Owner marked an "alignment issue": "Appointment status" wraps to two lines at that column
  // width while "From"/"To" do not, so the controls sat at different heights.
  const css = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');
  assert.match(css, /\.appointment-list-filters>div\{[^}]*justify-content:flex-end/);
  assert.match(css, /\.appointment-list-filters>div>label\{[^}]*white-space:nowrap/);
  assert.match(css, /\.appointment-list-filters>div\.row\{flex-direction:row\}/,
    'the Apply/Clear pair must stay horizontal');
});

test('the calendar service filter and Today button are gone', () => {
  // Owner crossed both out. Filtering the calendar to one service hid every other booking.
  assert.ok(!app.includes('id="calendarService"'));
  assert.ok(!app.includes('id="wkToday"'));
  assert.match(app, /let calendarServiceId=''/,
    'binding stays so the filter and slot preselection are harmless no-ops');
});

test('tiers read left to right as a progression', () => {
  const css = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');
  assert.match(css, /\.customer-tier-rungs\{[^}]*grid-template-columns:repeat\(auto-fit,minmax\(200px,1fr\)\)/);
});
