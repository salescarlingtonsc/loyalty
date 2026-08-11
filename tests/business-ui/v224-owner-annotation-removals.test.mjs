/* V224 — the owner's annotated screenshots, "remove" pass.
   Every assertion here corresponds to something struck through by hand. The point of the batch
   is that repeated scope wording and restated headings are noise: the branch is named once in
   the top bar, so it does not belong under four KPI tiles as well. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const rawApp = readFileSync(join(root, 'app', 'app.js'), 'utf8');
/* WORKSPACE_GENERATED_COPY_V97 is a generated translation table keyed by the English source.
   It keeps entries for strings that are no longer rendered, which is harmless — but it is data,
   not a render path, so it must not make a "this wording is gone" assertion fail. */
const app = rawApp.replace(/const WORKSPACE_GENERATED_COPY_V97=Object\.freeze\([\s\S]*?\n\}\);/, ' ');
const shell = readFileSync(join(root, 'app', 'index.html'), 'utf8');

test('V224 page subtitles the owner struck out are gone', () => {
  assert.doesNotMatch(app, /Find customers, manage consent, and follow up/);
  assert.doesNotMatch(app, /Manage your locations\. Staff assigned to a branch/);
  assert.doesNotMatch(app, /Manage staff access, invitations, roles and module permissions/);
  assert.doesNotMatch(app, /Active staff and roster-only teammates appear here first/);
  assert.doesNotMatch(app, /See today’s appointments by team member and add a booking/);
  assert.doesNotMatch(app, /Every programme you can run\. Choose one row/);
  // The headings themselves stay — only the restatement under them went.
  assert.match(app, /<h1>Customers<\/h1>/);
  assert.match(app, /<h1>Branches<\/h1>/);
  assert.match(app, /<h1>Staff Members<\/h1>/);
  assert.match(app, /<h2>Staff list<\/h2>/);
  assert.match(app, /title:'Appointments'/);
});

test('V224 the dashboard stops repeating the branch scope under every tile', () => {
  assert.doesNotMatch(app, /hint:`Valid original visits · \$\{scopeLabel\}`/);
  assert.doesNotMatch(app, /hint:`Net sales · \$\{scopeLabel\}`/);
  assert.doesNotMatch(app, /hint:`Inactive in this branch scope · \$\{scopeLabel\}`/);
  assert.doesNotMatch(app, /'Joined during the selected period\.'/);
  // An empty hint must not leave an empty element behind.
  assert.match(app, /\$\{metric\.hint\?`<span class="metric-hint">/);
});

test('V224 the Loyalty this period strip is gone', () => {
  // It duplicated the New customer members tile and belonged in Programmes.
  assert.match(app, /const loyaltyVisibleV170=false;/);
});

test('V224 the top bar no longer carries the awaiting-payment pill', () => {
  assert.doesNotMatch(app, /topbar-branch-withheld-v217/);
  assert.doesNotMatch(shell, /topbar-branch-withheld-v217/);
  // No orphaned binding left behind — that is how the dashboard broke once.
  const fnStart = app.indexOf('async function hydrateProfileBranchSelectorV158');
  const fn = app.slice(fnStart, app.indexOf('\nasync function ', fnStart + 1));
  assert.doesNotMatch(fn, /\bwithheld\b/);
});

test('V224 Record sale placeholder is not a real-looking number', () => {
  // "8186 3833" read as a value already typed in.
  assert.doesNotMatch(app, /placeholder="8186 3833"/);
  assert.match(app, /placeholder="···· ····"/);
});

test('V224 the earning row is called Point system', () => {
  assert.doesNotMatch(app, />Earn<\/b>/);
  // V271 superseded the paused suffix: the owner struck "paused" out of this heading and wrote
  // "Point System" beside it, so the heading is now unconditional and the state lives in the pill.
  assert.doesNotMatch(app, /Point system paused/);
  assert.match(app, /title:'Point system'/);
  assert.match(app, /<b>Point system<\/b>/);
});
