/* W4G / nestly_v807 — "Anyone available" on a staff reschedule must actually un-assign.

   THE DEFECT. public.staff_reschedule_and_confirm_booking_request_v329 applied the staff choice
   as `staff_id = coalesce(p_staff, staff_id)`, so NULL meant "leave it alone". W3B/F075 added the
   empty "Anyone available" option to both reschedule forms and sent its value through as
   p_staff:null, which kept an already-unassigned request unassigned — but could never clear a
   team member the customer had named. Proven against production (rolled back): the request was
   confirmed with the original member still on it, and the appointment was booked with them.

   THE REGRESSION. The migration adds p_clear_staff; these tests EXECUTE the browser helper that
   decides its value, so they fail if the empty option stops clearing, if a named member is
   accidentally reported as a clear, or if a missing select is read as a request to un-assign. */
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
  const b = appJs.indexOf(to, a); assert.ok(b > a, `missing: ${to} after ${from}`);
  return appJs.slice(a, b);
};

/* The real source of the helper, executed — not grepped. */
const helper = vm.runInNewContext(
  `${section('  const rescheduleStaffChoiceV695=staffSelect=>{', '\n  const staffColor=')}; rescheduleStaffChoiceV695`,
  {});
/* The helper builds its object inside the VM realm, so it does not deepStrictEqual a literal
   from this realm. Copy the two fields we care about into a plain local object. */
const rescheduleStaffChoiceV695 = select => {
  const sent = helper(select);
  return { p_staff: sent.p_staff, p_clear_staff: sent.p_clear_staff };
};

test('W4G/v807 picking "Anyone available" asks the server to clear the assignment', () => {
  assert.deepEqual(rescheduleStaffChoiceV695({ value: '' }),
    { p_staff: null, p_clear_staff: true });
});

test('W4G/v807 picking a team member names them and does not clear', () => {
  assert.deepEqual(rescheduleStaffChoiceV695({ value: 's-2' }),
    { p_staff: 's-2', p_clear_staff: false });
});

test('W4G/v807 a form with no staff select never asks to un-assign', () => {
  /* p_staff:null on its own is "unchanged", which is the correct outcome when the choice was
     never offered. Reading a missing element as an empty choice would silently strip the
     customer's team member on any form that does not carry the select. */
  assert.deepEqual(rescheduleStaffChoiceV695(null),
    { p_staff: null, p_clear_staff: false });
  assert.deepEqual(rescheduleStaffChoiceV695(undefined),
    { p_staff: null, p_clear_staff: false });
});

test('W4G/v807 the two arguments are never both set — the server refuses that pair', () => {
  for (const select of [{ value: '' }, { value: 's-1' }, null]) {
    const sent = rescheduleStaffChoiceV695(select);
    assert.ok(!(sent.p_clear_staff && sent.p_staff !== null),
      'p_clear_staff with a named member is refused by nestly_v807 with 22023');
  }
});

test('W4G/v807 both reschedule forms send the flag, and the old shape is gone', () => {
  assert.equal(appJs.split('...rescheduleStaffChoiceV695(staffSelect)').length - 1, 2,
    'the banner card and the calendar-tile dialog both go through the helper');
  assert.ok(!appJs.includes('p_staff:staffSelect?.value||null'),
    'no reschedule form still sends the bare select value, which could not clear an assignment');
});
