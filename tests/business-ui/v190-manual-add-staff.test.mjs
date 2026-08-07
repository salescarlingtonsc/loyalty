import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

test('a teammate can be added by hand, not only by CSV import or invite', () => {
  // Owner: "add staff - only import, cannot manually add staff". The single "Add staff" control
  // switched to the Invites tab, and the other route was importBtn('staff') — a CSV import.
  assert.match(app, /id="staffManualAddCard"/);
  assert.match(app, /id="staffAddName"/);
  assert.match(app, /addTop\.addEventListener\('click',openManualAdd\)/);
  assert.ok(!app.includes("addTop.addEventListener('click',()=>setTab('invite'))"),
    'Add staff must no longer bounce the owner to the Invites tab');
});

test('a manually added teammate is roster-only and consumes no seat', () => {
  /* V207 widened this handler: the owner asked for the full profile at add time rather than
     "add, then fill in later", so the slice is longer and the role is now a chosen value rather
     than a hardcoded 'staff'. What this test protects — roster-only, no login, no billable seat —
     is unchanged and asserted below. */
  const i = app.indexOf("#staffAddSave')?.addEventListener");
  const src = app.slice(i, i + 3600);
  assert.match(src, /full_name:name,role,active:true,title/);
  assert.match(src, /const role=val\('#staffAddRole'\)\|\|'staff'/,
    'the role still defaults to staff when nothing is chosen');
  // The insert must not SET user_id (mentioning it in a comment is fine): a roster-only
  // teammate has no login, and a seat is billed per active user_id.
  assert.ok(!/insert\(\{[^}]*user_id/.test(src),
    'user_id must stay NULL — no login, no billable seat');
  // staff.title is the real column; job_title does not exist and would fail the insert.
  assert.ok(!app.includes('job_title:title'));
});

test('a new teammate is immediately rosterable and creditable', () => {
  const i = app.indexOf("#staffAddSave')?.addEventListener");
  // V207 widened the handler; the branch assignment now sits further down the same block
  const src = app.slice(i, i + 3600);
  assert.match(src, /from\('staff_branches'\)\.insert/);
  assert.match(src, /eq\('active',true\)/);
});
