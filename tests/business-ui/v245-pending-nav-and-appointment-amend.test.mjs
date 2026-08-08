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

test('V245 Pending setup is reachable from the nav, beside the other two', () => {
  const links = app.slice(app.indexOf('const links=[\n    [\'#/grow\',\'Programmes list\']'));
  const block = links.slice(0, links.indexOf('];') + 2);
  assert.match(block, /\['#\/grow','Programmes list'\]/);
  assert.match(block, /\['#\/grow\/ongoing','Ongoing programmes'\]/);
  assert.match(block, /\['#\/grow\/available','Pending setup'\]/);
});

test('V245 nav row, page heading and tile group all say the same words', () => {
  // The heading for the filtered views no longer invents its own vocabulary.
  assert.match(app, /programmeView==='ongoing'\?'Ongoing programmes':programmeView==='available'\?'Pending setup':'List'/);
  // ...and they are the exact strings the V244 groups use inside the list.
  assert.match(app, /growTileSectionV244\('Ongoing programmes'/);
  assert.match(app, /growTileSectionV244\('Pending setup'/);
  assert.doesNotMatch(app, /programmeView==='available'\?'To set up'/);
});

test('V245 the available view still filters to the non-running rows', () => {
  // The row filter is the thing that makes the destination truthful — unchanged by the rename.
  assert.match(app, /if\(\['ongoing','available'\]\.includes\(programmeView\)\)\{/);
  assert.match(app, /const show=programmeView==='ongoing'\?isOngoing:!isOngoing;/);
});

test('V245 opening a booked appointment shows the amend fields immediately', () => {
  const render = app.slice(app.indexOf('function renderAppointmentDetails('), app.indexOf('editForm.onsubmit='));
  // Expanded on open, with the toggle telling assistive tech the truth.
  assert.match(render, /editForm\.hidden=false;toggle\.setAttribute\('aria-expanded','true'\);/);
  // Focus is only stolen when the caller explicitly asked to edit.
  assert.match(render, /if\(startEditing\)requestAnimationFrame\(\(\)=>\$\('appointmentEditDate'\)\?\.focus\(\)\);/);
  assert.doesNotMatch(render, /if\(startEditing\)\{editForm\.hidden=false;/);
  // The toggle still collapses it — this adds a default, it does not remove the control.
  assert.match(render, /toggle\.onclick=\(\)=>\{const open=editForm\.hidden;editForm\.hidden=!open;/);
});

test('V245 the popup can change staff, time and details, and is gated on write access', () => {
  const render = app.slice(app.indexOf('function renderAppointmentDetails('), app.indexOf('editForm.onsubmit='));
  // Staff reassignment is a real control listing that branch's people, defaulting to the current one.
  assert.match(render, /<select id="appointmentEditStaff" required>\$\{branchStaff\(item\.branch_id\)\.map\(person=>`<option value="\$\{person\.id\}" \$\{person\.id===item\.staff_id\?'selected':''\}/);
  for (const field of ['appointmentEditDate', 'appointmentEditTime', 'appointmentEditDuration', 'appointmentEditNote']) {
    assert.match(render, new RegExp(`id="${field}"`), `${field} must be amendable`);
  }
  // Only a booked appointment the user may write is amendable — the expansion cannot bypass that.
  assert.match(app, /const amendableBooked=item\.status==='booked'&&canWrite;/);
  assert.match(render, /\$\{amendableBooked\?`<p class="muted small"/);
});
