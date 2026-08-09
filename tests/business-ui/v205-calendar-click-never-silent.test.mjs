import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V205 — owner, twice: "not able to click into the calendar details".
   Three passes failed to find this because every layer I could inspect was correct: the handler
   IS bound in every view, the id IS in calendarItems, the day view stacks the event above the
   blocked window, and the detail read's branch_id filter IS satisfied. What was wrong is that the
   handler `return`ed silently on a miss — so a tap that did not resolve produced NOTHING: no
   dialog, no toast, no clue whether the owner had missed the button or the app had failed.
   A control that can fail without saying so is the defect, whatever the trigger. */

const app = readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', 'app/app.js'), 'utf8');

test('a calendar tap can no longer end in silence', () => {
  // the old shape: find, then bail with no feedback
  assert.doesNotMatch(app, /calendarItems\.find\(a=>a\.id===button\.dataset\.appointment\);if\(!item\)return;/);
  assert.match(app, /const openFromButton=\(button,id,\{startEditing=false\}=\{\}\)=>\{/);
  assert.match(app, /return toast\('That appointment could not be opened\. Refresh the calendar and try again\.'\)/);
});

test('the lookup is an optimisation, not a precondition', () => {
  // the button carries the branch, which is all the detail read needs besides the id
  /* V248: this used to pin `const branchId=button.dataset.appointmentBranch||branchId;` — a const
     initialised from itself, so the fallback V205 added threw a TDZ ReferenceError the moment it
     was needed. The guarantee under test is the fallback, not the name it used. */
  assert.match(app, /const fallbackBranchV248=button\.dataset\.appointmentBranch\|\|branchId;/);
  assert.doesNotMatch(app, /const branchId=button\.dataset\.appointmentBranch\|\|branchId;/);
  assert.match(app, /return openAppointmentDetails\(\{id,branch_id:fallbackBranchV248\},\{startEditing\}\)/);
  assert.ok((app.match(/data-appointment-branch="/g) || []).length >= 3,
    'every rendered appointment button must carry its own branch');
});

test('both the view and the amend paths go through it', () => {
  assert.match(app, /openFromButton\(button,button\.dataset\.appointment\)\)/);
  assert.match(app, /openFromButton\(button,button\.dataset\.appointmentAmend,\{startEditing:true\}\)\)/);
});

/* The identifier guard that V203 added for the dashboard, applied here too: I reached for a
   `tillBranchIdForCalendar()` helper that does not exist while writing this very fix, which is
   the same class of bug that took the dashboard down this morning. */
test('the calendar renderer references no identifier it does not declare', () => {
  const start = app.indexOf('async function appointmentsPage');
  assert.ok(start > 0);
  const next = app.indexOf('\nasync function ', start + 10);
  const body = app.slice(start, next > 0 ? next : app.length);
  assert.doesNotMatch(body, /tillBranchIdForCalendar/);
  assert.match(body, /let branchId=/, 'branchId must be declared in this scope, not assumed');
});
