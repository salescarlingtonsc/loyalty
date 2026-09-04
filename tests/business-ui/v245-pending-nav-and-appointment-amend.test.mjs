/* V245 — two owner reports.
   "Pending setup (3) — where is it?" The V244 group exists inside the Programmes list, but the
   filtered view for it had no nav row (V180 had removed it as a duplicate door) and the page
   called it "To set up", so nothing in the menu matched the words the owner was given.
   "when i click in jeffrey tan meng lee - i need to have pop up to amend and change details. or
   change staff if needed to" — the amend form (date, time, duration, staff, note) already
   existed but was folded behind a second click, so opening an appointment read as view-only. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

/* V250 supersedes the nav half of V245: the owner struck out BOTH sub-rows, so Pending setup is
   no longer reached from a menu row — it is a section the Programmes list opens with, and the
   nav is one flat "Programmes" link onto that list. The destination it names is what still has
   to be true, which the next test and the filter test below both pin. */
test('V250 the Programmes nav is one flat link, with no sub-rows left', () => {
  /* V294: Programmes became a group whose children are the page's own three views — still no
     per-module sub-rows (the thing V250 removed stays removed). */
  assert.match(app, /\{key:'grow',icon:'star',label:'Rewards & Offer'/);
  assert.match(app, /views:\[\['Overview','#\/grow\/overview','reports'\],\['Rewards Programme','#\/grow','star'\],\s*\['Limited Offer','#\/grow\/offers','tag'\],\['History','#\/grow\/history','waitlist'\]\]/);
  assert.doesNotMatch(app, /'Programmes list'/);
  assert.doesNotMatch(app, /\['#\/grow\/ongoing'/);
  assert.doesNotMatch(app, /\['#\/grow\/available'/);
});

test('V245 nav row, page heading and tile group all say the same words', () => {
  // The heading for the filtered views no longer invents its own vocabulary.
  /* V301 ADDITION (owner 2026-08-13, the one-page setup wizard): the fourth view names itself in
     the same ternary. The V245 vocabulary — Ongoing programmes / Pending setup / List — is
     unchanged, which is what this assertion exists to protect. */
  assert.match(app, /programmeView==='ongoing'\?'Ongoing programmes':programmeView==='available'\?'Pending setup':programmeView==='setup'\?'Set up rewards':'Rewards Programme'/);
  // ...and they are the exact strings the V244 groups use inside the list.
  /* V343/V357 replaced the two fixed sections (Ongoing programmes / Pending setup) with one
     filter strip over the same tiles; "Not set up" is still a first-class view of the list, which
     is what this nav test is about. */
  assert.match(app, /data-grow-tile-filter-v357="pending">Not set up \(\$\{growDisplayPendingV343\.length\}\)/);
  assert.doesNotMatch(app, /growTileSectionV244\(/,
    'the two fixed sections were replaced by the V357 filter strip, not kept alongside it');
  assert.doesNotMatch(app, /programmeView==='available'\?'To set up'/);
});

test('V245 the available view still filters to the non-running rows', () => {
  // The row filter is the thing that makes the destination truthful — unchanged by the rename.
  assert.match(app, /if\(\['ongoing','available'\]\.includes\(programmeView\)\)\{/);
  assert.match(app, /const show=programmeView==='ongoing'\?isOngoing:!isOngoing;/);
});

test('V375 the amend form is minimised until a tab is pressed, and Amend still opens it', () => {
  const render = app.slice(app.indexOf('function renderAppointmentDetails('), app.indexOf('editForm.onsubmit='));
  /* V375 (owner, photo 14: "minimise this" across the amend form) OVERRULES V245's forced-open
     default. The guarantee is now the pair: nothing is open on a plain view, and the Amend entry
     point — the one that passes startEditing — still lands straight in the form with focus. */
  assert.match(render, /showOutcomePanelV375\(startEditing\?'amend':null\);/);
  /* v760: the Amend entry point now opens the slot picker rather than focusing a date input. */
  assert.match(render, /if\(startEditing\)openAmendPickerV760\(\);/);
  assert.doesNotMatch(render, /editForm\.hidden=false;toggle\.setAttribute\('aria-expanded','true'\);/);
  // The two outcomes are tabs over one panel area, and only one can be open.
  assert.match(render, /id="appointmentEditToggle" role="tab"/);
  assert.match(render, /id="appointmentCompleteTabV375" role="tab"/);
  assert.match(render, /const amendOpen=which==='amend',completeOpen=which==='complete';/);
});

test('V245 the popup can change staff, time and details, and is gated on write access', () => {
  const render = app.slice(app.indexOf('function renderAppointmentDetails('), app.indexOf('editForm.onsubmit='));
  // Staff reassignment is a real control listing that branch's people, defaulting to the current one.
  /* v760: staff reassignment is now the customer flow's tappable team cards over the same branch
     roster, with the current staff preselected, writing the hidden appointmentEditStaff field the
     save path already read. */
  assert.match(render, /const people=branchStaff\(item\.branch_id\);/);
  assert.match(render, /data-amend-staff="\$\{esc\(person\.id\)\}"/);
  assert.match(render, /<input type="hidden" id="appointmentEditStaff" value="\$\{esc\(item\.staff_id\|\|''\)\}">/);
  for (const field of ['appointmentEditDate', 'appointmentEditTime', 'appointmentEditDuration', 'appointmentEditNote']) {
    assert.match(render, new RegExp(`id="${field}"`), `${field} must be amendable`);
  }
  // Only a booked appointment the user may write is amendable — the expansion cannot bypass that.
  assert.match(app, /const amendableBooked=item\.status==='booked'&&canWrite;/);
  assert.match(render, /\$\{amendableBooked\?`<p class="muted small"/);
});
