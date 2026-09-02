/* W3B audit wave — regressions for F072, F073, F075, F096, F103 and F104.

   Each test extracts the real source of the function or template under test and EXECUTES it
   against stubs, so the assertions fail when the behaviour regresses rather than when the
   spelling changes. F101 (the WhatsApp Inbox unread badge) has no test here on purpose: no
   server route existed that could clear support_conversations_v530.unread_count without sending a
   reply, so it needed a migration; nestly_v688 added one and its regressions live in
   tests/business-ui/f101-support-mark-read.test.mjs. */
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
const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* ---------------------------------------------------------------- F072 */

const buildSetStatus = ({ calendarItems, canComplete = true }) => {
  const rpcCalls = [];
  const toasts = [];
  const src =
    section('const appointmentOutcomeIsDue=', ';\n') + ';\n' +
    section('  async function setStatus(id,status,knownItem=null){', '\n  /* V288 (audit A2, HIGH 5).');
  const context = {
    calendarItems,
    canComplete,
    toast: message => toasts.push(String(message)),
    confirmActionV386: async () => true,
    statusGate: { begin: () => () => true },
    sb: { rpc: async (name, args) => { rpcCalls.push({ name, args }); return { data: {}, error: null }; } },
    S: { biz: { id: 'biz-1' } },
    fail: error => { throw error; },
    workspaceTemplateTextV97: () => 'status saved',
    workspaceTranslationV97: value => value,
    $: () => ({ innerHTML: '' }),
    loadCalendar: () => {},
  };
  const setStatus = vm.runInNewContext(`${src}; setStatus`, context);
  return { setStatus, rpcCalls, toasts };
};

const pastAppointment = { id: 'appt-1', starts_at: new Date(Date.now() - 3600000).toISOString() };
const futureAppointment = { id: 'appt-2', starts_at: new Date(Date.now() + 3600000).toISOString() };

test('F072 an overdue appointment absent from the staff-filtered calendar can still be completed', async () => {
  /* The dashboard "Today schedule" is unfiltered, so a non-owner opening a colleague's
     appointment holds a row that calendarItems (filtered to their own staff id) does not have. */
  const { setStatus, rpcCalls } = buildSetStatus({ calendarItems: [] });
  assert.equal(await setStatus('appt-1', 'completed', pastAppointment), true);
  assert.equal(await setStatus('appt-1', 'no_show', pastAppointment), true);
  assert.deepEqual(rpcCalls.map(call => call.args.p_status), ['completed', 'no_show']);
  assert.equal(rpcCalls[0].name, 'set_appointment_status_v47');
});

test('F072 the "not started yet" rule still holds when the caller hands over the item', async () => {
  const { setStatus, rpcCalls, toasts } = buildSetStatus({ calendarItems: [futureAppointment] });
  assert.equal(await setStatus('appt-2', 'completed', futureAppointment), false);
  assert.equal(rpcCalls.length, 0);
  assert.match(toasts.join(' '), /only be recorded after the appointment starts/);
});

test('F072 the calendar-row fallback is unchanged when no item is passed', async () => {
  const { setStatus, rpcCalls } = buildSetStatus({ calendarItems: [pastAppointment] });
  assert.equal(await setStatus('appt-1', 'completed'), true, 'an inline .statusAction row still works');
  assert.equal(rpcCalls.length, 1);
  const { toasts } = { toasts: [] };
  void toasts;
  const unknown = buildSetStatus({ calendarItems: [] });
  assert.equal(await unknown.setStatus('ghost', 'completed'), false, 'a genuinely unknown id is still refused');
  assert.equal(unknown.rpcCalls.length, 0);
});

test('F072 the detail dialog hands its loaded appointment to setStatus', () => {
  assert.match(section("dialog.querySelectorAll('.statusAction')", 'rebookFromAppointmentV640={'),
    /if\(!await setStatus\(item\.id,status,item\)\)return;/);
});

/* ---------------------------------------------------------------- F073 */

const runWaitlistBookGate = ({ seated, appointmentsWritable, waitlistWritable }) => {
  const src = section('  const canHandOffToAppointmentsV571=', '\n  /* V288 (audit A2 HIGH 1)');
  return vm.runInNewContext(
    `${src}; ({canHandOffToAppointmentsV571, seatWalkInDirectlyV571, canBook})`,
    {
      canWriteModule: module => module === 'appointments' ? appointmentsWritable : false,
      canWrite: waitlistWritable,
      seatedWithoutAppointmentsV288: seated,
    });
};

test('F073 a seated business without an appointments surface books through the waitlist itself', () => {
  const gate = runWaitlistBookGate({ seated: true, appointmentsWritable: false, waitlistWritable: true });
  assert.equal(gate.seatWalkInDirectlyV571, true);
  assert.equal(gate.canBook, true, 'the Book control is offered, backed by the waitlist status write');
});

test('F073 a seated business that can write appointments uses the appointment form', () => {
  const gate = runWaitlistBookGate({ seated: true, appointmentsWritable: true, waitlistWritable: true });
  assert.equal(gate.seatWalkInDirectlyV571, false);
  assert.equal(gate.canBook, true);
});

test('F073 a non-seated business is unchanged: Book needs appointment write access', () => {
  assert.equal(runWaitlistBookGate({ seated: false, appointmentsWritable: false, waitlistWritable: true }).canBook, false);
  assert.equal(runWaitlistBookGate({ seated: false, appointmentsWritable: true, waitlistWritable: false }).canBook, true);
});

const runWlBook = async ({ seatWalkInDirectlyV571, canBook = true, row }) => {
  const src = section('  window.wlBook=async id=>{', '\n  window.wlCalled=');
  const state = { navs: [], toasts: [], updates: [], loads: 0, pendingWaitlistBookIdV571: '' };
  const context = {
    window: {},
    currentRows: row ? [row] : [],
    canBook,
    seatWalkInDirectlyV571,
    toast: message => state.toasts.push(String(message)),
    confirmActionV386: async () => true,
    updateWl: async (id, status) => { state.updates.push({ id, status }); return true; },
    loadWl: () => { state.loads += 1; },
    nav: hash => state.navs.push(hash),
    waitlistWantedInputValueV575: () => '',
    pendingWaitlistBookIdV571: '',
    pendingApptClientId: '',
    pendingApptPrefillV575: null,
  };
  const wlBook = vm.runInNewContext(`${src}; window.wlBook`, context);
  await wlBook(row?.id);
  state.pendingWaitlistBookIdV571 = context.pendingWaitlistBookIdV571;
  return state;
};

test('F073 seating a walk-in resolves the queue row instead of opening a dead-end Bookings page', async () => {
  const state = await runWlBook({ seatWalkInDirectlyV571: true, row: { id: 'w-1', name: 'Ada' } });
  assert.deepEqual(state.updates, [{ id: 'w-1', status: 'booked' }],
    "'booked' is one of the four values waitlist_status_check allows");
  assert.deepEqual(state.navs, [], 'nothing navigates to a page that cannot complete the walk-in');
  assert.equal(state.loads, 1, 'the queue is redrawn so the row visibly leaves');
  assert.match(state.toasts.join(' '), /seated/i);
});

test('F073 the appointment hand-off path is untouched', async () => {
  const state = await runWlBook({ seatWalkInDirectlyV571: false, row: { id: 'w-2', name: 'Ada', client_id: 'c-1' } });
  assert.deepEqual(state.navs, ['#/appointments']);
  assert.equal(state.pendingWaitlistBookIdV571, 'w-2', 'the row is resolved only once the appointment saves');
  assert.deepEqual(state.updates, [], 'opening a form is not a booking');
});

test('F073 no waitlist path sends a walk-in to Bookings any more', () => {
  const wlBook = section('  window.wlBook=async id=>{', '\n  window.wlCalled=');
  assert.doesNotMatch(wlBook, /nav\('#\/bookings'\)/,
    'bookingsPage never reads pendingWaitlistBookIdV571 and has no create-a-request control');
});

/* ---------------------------------------------------------------- F075 */

const rescheduleStaffOptionsV329 = vm.runInNewContext(
  `${section('  const rescheduleStaffOptionsV329=', ';\n  const staffColor=')}; rescheduleStaffOptionsV329`,
  { staff: [{ id: 's-1', full_name: 'Aisha' }, { id: 's-2', full_name: 'Bo' }], staffLabel: p => p.full_name, esc });

const selectedValues = html => [...html.matchAll(/<option value="([^"]*)"\s*selected>/g)].map(m => m[1]);

test('F075 an unassigned booking request keeps "Anyone available" selected', () => {
  const html = rescheduleStaffOptionsV329(null);
  assert.match(html, /<option value="" selected>Anyone available<\/option>/);
  assert.deepEqual(selectedValues(html), [''], 'no staff member is silently pre-selected');
});

test('F075 an assigned request still shows its own team member', () => {
  const html = rescheduleStaffOptionsV329('s-2');
  assert.deepEqual(selectedValues(html), ['s-2']);
  assert.match(html, /<option value=""\s*>Anyone available<\/option>/, 'and unassigning is offerable');
});

test('F075 both reschedule forms build their select from the shared helper', () => {
  assert.match(section('<select id="pendingRescheduleStaffV329-', '</select>'),
    /\$\{rescheduleStaffOptionsV329\(r\.staff_id\)\}/);
  assert.match(section('const staffOptions=', ';\n'), /rescheduleStaffOptionsV329\(row\.staff_id\)/);
  /* An empty select value reaches the RPC as null, which
     staff_reschedule_and_confirm_booking_request_v329 accepts (staff_id = coalesce(p_staff,
     staff_id)) — verified against production. */
  assert.equal(appJs.split("p_staff:staffSelect?.value||null").length - 1, 2);
});

/* ---------------------------------------------------------------- F096 */

const lockedCadence = billing => vm.runInNewContext(
  `${section('    const plansV620=Array.isArray(billing.plans)', '\n    const capacity=')}; cadence`,
  { billing });

test('F096 a lapsed monthly workspace is reactivated on its own monthly cadence', () => {
  assert.equal(lockedCadence({ terms: { cadence: 'monthly' }, plans: [{ cadence: 'monthly' }, { cadence: 'annual' }] }), 'monthly');
});

test('F096 an annual workspace still reactivates annually', () => {
  assert.equal(lockedCadence({ terms: { cadence: 'annual' }, plans: [{ cadence: 'monthly' }, { cadence: 'annual' }] }), 'annual');
});

test('F096 with no stored cadence, or one the payload no longer offers, it falls back to annual', () => {
  assert.equal(lockedCadence({ terms: {}, plans: [{ cadence: 'monthly' }, { cadence: 'annual' }] }), 'annual');
  assert.equal(lockedCadence({ terms: { cadence: 'monthly' }, plans: [{ cadence: 'annual' }] }), 'annual');
  assert.equal(lockedCadence({ terms: { cadence: 'monthly' } }), 'monthly', 'a payload without plans still honours a valid cadence');
  assert.equal(lockedCadence({}), 'annual');
});

/* ---------------------------------------------------------------- F103 / F104 */

test('F103 the Expenses gate follows the top-bar branch scope, not an all-branch demand', () => {
  const tail = "p_module:'expenses'})";
  const end = appJs.indexOf(tail);
  assert.ok(end > -1, 'the expenses scope gate is still called');
  const call = appJs.slice(appJs.lastIndexOf('sb.rpc(', end), end + tail.length);
  const recorded = [];
  const args = vm.runInNewContext(call, {
    sb: { rpc: (name, payload) => { recorded.push({ name, payload }); return payload; } },
    S: { biz: { id: 'biz-1' } },
    selectedBranchId: 'branch-2',
  });
  assert.equal(recorded[0].name, 'require_module_scope_v145');
  assert.equal(args.p_module, 'expenses');
  assert.equal(args.p_branch, 'branch-2',
    'app.can_see_branch(business, NULL) is owner/admin-only, which locked out branch-scoped bookkeepers');
  const businessWide = vm.runInNewContext(call, {
    sb: { rpc: (name, payload) => payload }, S: { biz: { id: 'biz-1' } }, selectedBranchId: '',
  });
  assert.equal(businessWide.p_branch, null, 'business-wide scope is still asked for as null');
});

const expenseScopeHtml = ({ selectedBranchId, expenseBranches }) => vm.runInNewContext(
  '`' + section('<select id="exBranch">', '</select>') + '</select>`',
  { selectedBranchId, expenseBranches, esc });

const branches = [
  { id: 'b-1', name: 'Orchard', is_default: true },
  { id: 'b-2', name: 'Tampines', is_default: false },
];

test('F104 the Add-expense scope defaults to the branch currently in scope', () => {
  const html = expenseScopeHtml({ selectedBranchId: 'b-2', expenseBranches: branches });
  assert.deepEqual(selectedValues(html), ['b-2'], 'not the tenant default the list is not showing');
});

test('F104 with no branch in scope the tenant default is still pre-selected', () => {
  assert.deepEqual(selectedValues(expenseScopeHtml({ selectedBranchId: '', expenseBranches: branches })), ['b-1']);
  assert.deepEqual(selectedValues(expenseScopeHtml({ selectedBranchId: null, expenseBranches: branches })), ['b-1']);
});

test('F104 business-wide overhead remains an explicit choice', () => {
  assert.match(expenseScopeHtml({ selectedBranchId: 'b-2', expenseBranches: branches }),
    /<option value="">Business-wide overhead<\/option>/);
});
