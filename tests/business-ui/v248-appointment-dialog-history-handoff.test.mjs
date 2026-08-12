import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V248 — owner: "Cannot click???" on a Day-view appointment block (iPad Safari).
   The fourth report of this same symptom, after V200 (week-view stacking), V205 (silent miss)
   and V212 (sticky header over the block). None of them was the cause of THIS one, because the
   handler was never the problem: the tap DID run it.

   openAppointmentDetails opens a loading dialog, reads the row, then opens the detail dialog.
   CUI.activateDialog pushes one history entry per dialog and unwinds it with history.back(),
   which is ASYNCHRONOUS. The loading dialog's back() therefore landed AFTER the detail dialog
   had pushed its own entry, and the detail dialog's popstate listener read that pop as a Back
   press and closed itself on arrival. Open-then-instantly-close is indistinguishable from
   "nothing happened".

   app/customer-ui.js documents this exact hazard in its v183 comment and ships the remedy —
   close the outgoing sheet with {handOffHistory:true} and let the incoming one adopt the entry
   via inheritHistoryId. The customer offer/business sheets use it; this business-side
   loading -> detail handoff never did.

   These tests pin the MECHANISM, not the existence of a button. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(repoRoot, 'app/app.js'), 'utf8');
const customerUi = readFileSync(resolve(repoRoot, 'app/customer-ui.js'), 'utf8');

const calendar = app.slice(app.indexOf('async function appointmentsPage'),
  app.indexOf('async function waitlistPage'));

test('the loading dialog hands its history entry over instead of unwinding it', () => {
  assert.ok(calendar.length > 1000, 'appointmentsPage body must be locatable');
  // the old shape: unwind (history.back) and then push a second entry on top of the pending pop
  assert.doesNotMatch(calendar, /removeLoading\(\);renderAppointmentDetails\(data,\{startEditing\}\)/,
    'the success path must not unwind the loading entry while opening the detail dialog');
  assert.match(calendar, /const appointmentDialogHandOffV248=CUI\.currentDialogHistoryId\?\.\(\)\|\|0;/);
  assert.match(calendar, /removeLoading\(\{handOffHistory:appointmentDialogHandOffV248>0\}\);/);
  assert.match(calendar,
    /renderAppointmentDetails\(data,\{startEditing,inheritHistoryId:appointmentDialogHandOffV248\}\)/);
});

test('the detail dialog adopts the handed-over entry rather than pushing a second one', () => {
  assert.match(calendar,
    /function renderAppointmentDetails\(item,\{startEditing=false,inheritHistoryId=0\}=\{\}\)/);
  assert.match(calendar,
    /closeAppointmentDialog=CUI\.activateDialog\(dialog,\{onClose:close,initialFocus:'#appointmentDialogClose',inheritHistoryId\}\)/);
});

test('removeLoading can actually forward the handoff to the closer', () => {
  // a handOffHistory argument that never reaches CUI's returned closer is a no-op fix
  assert.match(calendar,
    /const removeLoading=\(\{restoreFocus=true,handOffHistory=false\}=\{\}\)=>\{[\s\S]{0,200}deactivate\(\{restoreFocus,handOffHistory\}\)/);
});

test('the CUI contract the fix relies on still exists', () => {
  // if either half of the v183 mechanism is removed, this fix silently stops working
  assert.match(customerUi, /return \(\{restoreFocus=true,handOffHistory=false\}=\{\}\)=>\{/);
  assert.match(customerUi, /if\(handOffHistory\)closedByUs=true;/);
  assert.match(customerUi,
    /const inherited=Number\(inheritHistoryId\)>0&&currentDialogHistoryId\(\)===Number\(inheritHistoryId\);/);
  assert.match(customerUi, /currentDialogHistoryId\s*\n?\s*\}\)/);
});

test('the V205 fallback is no longer a self-referencing const', () => {
  /* `const branchId=button.dataset.appointmentBranch||branchId;` reads the binding it is
     declaring, so the branch V205 added specifically so a tap could not fail silently threw a
     TDZ ReferenceError the moment it ran — silence again, by a different route. */
  assert.doesNotMatch(app, /const branchId=button\.dataset\.appointmentBranch\|\|branchId;/);
  assert.match(calendar, /const fallbackBranchV248=button\.dataset\.appointmentBranch\|\|branchId;/);
  assert.match(calendar, /if\(!fallbackBranchV248\)return toast\('That appointment could not be opened/);
  assert.match(calendar, /openAppointmentDetails\(\{id,branch_id:fallbackBranchV248\},\{startEditing\}\)/);
  // and nothing else in the calendar may reintroduce the pattern
  assert.doesNotMatch(calendar, /const ([A-Za-z_$][\w$]*)=[^;\n]*\|\|\1;/);
});

test('the day view still wires its appointment buttons inside the captured route root', () => {
  // the layer three earlier fixes suspected: it is correct, and this pins it so the next
  // investigation does not have to re-derive it
  const renderDay = calendar.slice(calendar.indexOf('function renderDay(day)'),
    calendar.indexOf('function renderWeek('));
  assert.match(renderDay, /\$\('alist'\)\.innerHTML=`<div class="day-timeline-intro"/);
  assert.match(renderDay, /class="day-timeline-event\$\{inactiveV288\?' appointment-inactive-v288':''\}" data-appointment="\$\{item\.id\}"/);
  assert.match(renderDay, /wireBlockedTimeActions\(\);\s*wireAppointmentActions\(\);\s*\}/);
  assert.match(calendar, /<div id="alist"/, 'the day host must be part of the route root markup');
  assert.equal((app.match(/id="alist"/g) || []).length, 1,
    'a second #alist would make renderDay write outside the wired root');
});
