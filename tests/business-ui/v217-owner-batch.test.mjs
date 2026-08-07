/* V217 — the owner's nine-item batch. Each test names the report it answers.
   Server behaviour (the recent-window parameter and the staff reference code) is proved by the
   rolled-back production chains, 17/17. These assertions pin the client half. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const shell = readFileSync(join(root, 'app', 'index.html'), 'utf8');

function fn(name) {
  const start = app.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `${name} must exist`);
  return app.slice(start, app.indexOf('\nfunction ', start + 1));
}

/* (1)+(2) "it takes forever to load the dashboard" and "why i cannot load?" — one cause:
   an unpaid branch (active=false) became the reporting scope, which the server always refuses. */
test('V217 an inactive branch can never become the reporting scope', () => {
  const pick = fn('reportingOperationalBranchIdV155');
  assert.match(pick, /activeBranchesForScopeV217\(branches\)/);
  assert.doesNotMatch(pick, /return branches\[0\]/, 'the raw first branch is no longer the fallback');

  const normalise = fn('normaliseReportingScopeV155');
  assert.match(normalise, /activeBranchesForScopeV217\(branches\)\.map/,
    'an inactive branch must not authorise a saved scope either');

  const filter = fn('activeBranchesForScopeV217');
  assert.match(filter, /branch\.active!==false/);
});

test('V217 neither branch picker offers a branch the server will refuse', () => {
  // Top bar and the page-level filter both narrow to active branches...
  assert.equal((app.match(/activeBranchesForScopeV217\(branches\)/g) || []).length >= 3, true);
  // ...and neither still renders the old "(inactive)" option, which was the selectable trap.
  assert.doesNotMatch(app, /\(inactive\)/, 'an inactive branch must not be a selectable option');
  // The branch is named rather than silently vanishing.
  assert.match(app, /topbar-branch-withheld-v217/);
  assert.match(shell, /\.topbar-branch-withheld-v217\{/);
  const reason = fn('branchScopeUnavailableReasonV217');
  assert.match(reason, /waiting for payment/);
  assert.match(reason, /switched off/);
});

test('V217 a failed dashboard load stops looking like a load in progress', () => {
  // The "forever" was skeletons left shimmering under an error banner.
  const errorStart = app.indexOf('const showLoadError=(message,retryId');
  const dashboard = app.slice(errorStart, app.indexOf('killCharts();', errorStart));
  assert.match(dashboard, /if\(kpis\)kpis\.innerHTML='';/);
  assert.match(dashboard, /if\(insights\)insights\.innerHTML='';/);
  assert.match(dashboard, /if\(charts\)charts\.innerHTML='';/);
  assert.match(app, /branchScopeErrorHintV217\(error\)/);
});

test('V217 the owner is never shown a raw server scope code', () => {
  // Translated centrally so every surface benefits, not just the two that reported it.
  const rules = app.slice(app.indexOf('const OWNER_ERROR_NOISE_RULES_V170'), app.indexOf('const ownerErrorText'));
  assert.match(rules, /foreign_or_inactive_branch_scope/);
  assert.match(rules, /unauthorised_branch_scope\|branch_visibility/);
  assert.match(rules, /operational_branch_required_for_current_scope/);
  // The customer list rendered error.message straight through — that is what leaked the code.
  assert.match(app, /esc\(ownerErrorText\(error\)\|\|'Customers could not be loaded\.'\)/);
});

/* (3) "there must be a reference code here ... he can just take over as the staff" */
test('V217 a roster teammate can be given a reference code that claims their existing record', () => {
  assert.match(app, /create_staff_reference_code_v217/);
  // Offered only to someone who has no login yet — the whole point is taking over a roster row.
  assert.match(app, /\$\{!s\.user_id&&s\.active!==false\?`<button class="btn ghost sm" data-name="\$\{esc\(s\.full_name\|\|'this teammate'\)\}" onclick="staffReferenceCodeV217/);
  const handler = app.slice(app.indexOf('window.staffReferenceCodeV217='), app.indexOf('window.rvInv='));
  assert.match(handler, /their job title, commission, hours and past sales stay as they are/);
  assert.match(handler, /expires in 14 days and works once/);
  assert.match(handler, /staff-reference-code-v217/);
  assert.match(shell, /\.staff-reference-code-v217\{/);
});

/* (4) "instead of general visit, put ..." */
test('V217 real services lead the service picker instead of General visit', () => {
  const sync = fn('syncFormOptions');
  // A business with services preselects one, so an untouched form books the real thing.
  assert.match(sync, /:\(services\[0\]\?\.id\|\|''\);/);
  // General visit survives, last, and says what it is.
  assert.match(sync, /No specific service · general visit/);
  assert.doesNotMatch(sync, /<option value="">General visit<\/option>\$\{services\.map/,
    'General visit must no longer be the first option');
  // An already-chosen service is not silently swapped when options are rebuilt.
  assert.match(sync, /previousServiceV217/);
});

/* (5) "i selected kelvin - why it show devi next best time?" */
test('V217 the availability panel answers about the person actually selected', () => {
  const panel = app.slice(app.indexOf('const RECENT_WINDOWS_V217='), app.indexOf('async function renderAvailability'));
  assert.match(panel, /selectedStaffFreeFairer/);
  assert.match(panel, /selectedStaffFree/);
  // The fairer alternative is only named when it is genuinely fairer.
  assert.match(panel, /Number\(fairest\.recent_appointments\)<Number\(selectedEntry\.recent_appointments\)/);
  // Auto-assign still leads with the fairest, because that is what auto-assign does.
  assert.match(panel, /availableStaffMany/);
  assert.match(panel, /is-selected-v217/);
  assert.match(shell, /\.suggestionStaff\.is-selected-v217\{/);
});

/* (6) "recent appointment - how recent? maybe can reset per day/3 days/week/month?" */
test('V217 the recent window is stated and selectable, and drives the ranking', () => {
  const panel = app.slice(app.indexOf('const RECENT_WINDOWS_V217='), app.indexOf('async function renderAvailability'));
  assert.match(panel, /\{days:1,label:'day'\},\{days:3,label:'3 days'\},\{days:7,label:'week'\},\{days:30,label:'month'\}/);
  assert.match(panel, /recentInWindow/, 'the count must state its own window');
  assert.match(panel, /id="recentWindowV217"/);
  // Changing it re-asks the server, so the fairness order moves with the label rather than
  // the label drifting away from the advice.
  assert.match(panel, /recentWindowDaysV217=Number\(windowSelect\.value\)\|\|30;\s*\n\s*renderAvailability\(\)/);
  assert.match(app, /p_recent_days:recentWindowDaysV217/);
});

/* (7) "it shows appointment must be in the future (but it shows green bar to press?)" */
test('V217 a time that cannot be booked is not drawn as bookable', () => {
  const starts = app.slice(app.indexOf('function availableCalendarStarts('), app.indexOf('function recordedSchedule('));
  assert.match(starts, /earliestBookableMinute=-Infinity/);
  assert.match(starts, /if\(earliestBookableMinute===Infinity\)return \[\];/, 'a past day offers nothing');
  assert.match(starts, /const alreadyPassed=start<earliestBookableMinute;/);
  assert.match(starts, /if\(!alreadyPassed&&!hitsBreak/);
  // Today books forward from now; a past day books nothing; a future day books freely.
  assert.match(app, /const earliestBookableMinuteV217=day===todaySg[\s\S]{0,140}day<todaySg\?Infinity:-Infinity\)/);
  assert.match(app, /availableCalendarStarts\(column,earliestBookableMinuteV217\)/);
  // And the instruction stops saying "choose a green start time" when there is no green left.
  assert.match(app, /hasBookableV217/);
  assert.match(app, /This day has already passed/);
});

/* (8) "new appointment here does not work (in the header - beside record sale)" */
test('V217 the header New appointment button opens the booking form', () => {
  const wire = app.slice(app.indexOf('function wireGlobalActions()'), app.indexOf('function userDisplayNameV158'));
  assert.match(wire, /pendingOpenApptFormV217=canWriteModule\('appointments'\)/,
    'permission is re-read in this scope — canNewAppt belongs to globalActionsHtml');
  assert.match(wire, /nav\('#\/appointments'\)/);
  // Landing on the page already opens the form, and the flag is consumed once.
  assert.match(app, /const apptOpenFormV217=pendingOpenApptFormV217;pendingOpenApptFormV217=false;/);
  /* V218 corrected this: addDays is a const declared later in appointmentsPage, so computing a
     date here threw during the render and took the page down. No date is passed — #ad already
     carries todaySg. See tests/business-ui/v218-appointments-tdz.test.mjs. */
  assert.match(app, /if\(apptOpenFormV217&&!apptPrefillClient\)openNewAppointmentForm\(\{\}\)/);
  // Reset alongside the other consume-once deep-link vars.
  assert.match(app, /pendingApptClientId='';pendingOpenApptFormV217=false;/);
});
