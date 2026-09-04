/* v760 (owner, photo 2 — business Appointments → open an appointment → "Change appointment").
   The amend form used to ask the owner to TYPE a date and time blindly. It now shows the customer
   booking flow's two steps: tappable team-member cards, then day chips + a grid of the slots that
   are actually free.

   These are EXECUTABLE tests, not source greps. The real availability core is lifted out of
   app/app.js by brace-matched extraction and run against synthetic rosters, so the two guarantees
   that matter are proven by behaviour:
     (a) a slot occupied by ANOTHER appointment is not offered; and
     (b) the appointment being moved does not block itself — its own current slot is still offered.
   Both would have been invisible to a regex over the markup. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

/* Extract `function <name>(` ... matching close brace. Deliberately naive but exact: it starts at
   the real declaration in app/app.js and counts braces, so the test executes the shipped body
   rather than a transcription of it. */
function extractFunction(name) {
  const start = app.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `${name} must exist in app/app.js`);
  // Skip the parameter list first — a destructured parameter contains braces of its own.
  let parens = 0, bodyStart = -1;
  for (let i = app.indexOf('(', start); i < app.length; i++) {
    if (app[i] === '(') parens++;
    else if (app[i] === ')') { parens--; if (parens === 0) { bodyStart = app.indexOf('{', i); break; } }
  }
  assert.notEqual(bodyStart, -1, `${name} must have a body`);
  let depth = 0, seen = false;
  for (let i = bodyStart; i < app.length; i++) {
    if (app[i] === '{') { depth++; seen = true; }
    else if (app[i] === '}') { depth--; if (seen && depth === 0) return app.slice(start, i + 1); }
  }
  throw new Error(`unbalanced braces while extracting ${name}`);
}

/* The support the two extracted functions close over. `selectedCalendarServiceTiming` is only the
   DEFAULT for availableCalendarStarts and is never reached here — the amend picker always passes
   an explicit timing — so it throws if anything silently falls back to it. */
const support = `
  const eventParts=iso=>{const d=new Date(new Date(iso).getTime()+8*3600000);
    return {date:d.toISOString().slice(0,10),minutes:d.getUTCHours()*60+d.getUTCMinutes()}};
  const inactiveAppointmentStatuses=new Set(['cancelled','canceled','no_show','no-show']);
  const intervalsOverlap=(aStart,aEnd,bStart,bEnd)=>aStart<bEnd&&aEnd>bStart;
  const appointmentBufferedInterval=item=>{
    const from=eventParts(item.starts_at).minutes,to=eventParts(item.ends_at).minutes;
    return {from:from-Math.max(0,Number(item.services?.buffer_before_min)||0),
      to:to+Math.max(0,Number(item.services?.buffer_after_min)||0)};
  };
  const selectedCalendarServiceTiming=()=>{throw new Error('the amend picker must pass its own timing')};
`;

const build = new Function(`
  ${support}
  ${extractFunction('availableCalendarStarts')}
  ${extractFunction('amendAvailabilityDaysV760')}
  return {availableCalendarStarts,amendAvailabilityDaysV760};
`);
const { amendAvailabilityDaysV760 } = build();

const DAY = '2026-09-10';                    // a future day, so nothing is filtered as "already passed"
const sgAt = clock => `${DAY}T${clock}:00+08:00`;
const workingDay = () => ({ state: 'working', start: 9 * 60, end: 12 * 60, breaks: [] });
const run = (appointments, { duration = 60, excludeAppointmentId = null } = {}) =>
  amendAvailabilityDaysV760({
    days: [DAY], staffId: 'staff-1', appointments, blocks: [],
    timing: { duration, before: 0, after: 0 },
    today: '2026-09-01', todayMinutes: 600, excludeAppointmentId,
    scheduleFor: () => workingDay()
  })[0].starts;

test('v760 a slot another appointment occupies is not offered', () => {
  const free = run([{ id: 'other', staff_id: 'staff-1', status: 'booked', starts_at: sgAt('10:00'), ends_at: sgAt('11:00') }]);
  // A 60-minute visit inside 09:00–12:00 can start at 09:00, 09:15 … 11:00 when nothing is booked.
  const empty = run([]);
  assert.deepEqual(empty.slice(0, 3), [540, 555, 570]);
  assert.ok(empty.includes(600), 'control: 10:00 is free on an empty day');
  assert.ok(!free.includes(600), '10:00 must disappear once it is booked');
  // Everything the 10:00–11:00 booking overlaps for a 60-minute visit goes with it.
  for (const start of [540 + 15, 570, 600, 615, 645]) {
    assert.ok(!free.includes(start), `${start} overlaps the booked hour and must not be offered`);
  }
  assert.ok(free.includes(540), '09:00 still ends before the booking starts');
  assert.ok(free.includes(660), '11:00 starts as the booking ends');
});

test('v760 the appointment being moved does not block its own slot', () => {
  const moving = { id: 'moving', staff_id: 'staff-1', status: 'booked', starts_at: sgAt('10:00'), ends_at: sgAt('11:00') };
  assert.ok(!run([moving]).includes(600), 'control: without the exclusion it blocks itself');
  const free = run([moving], { excludeAppointmentId: 'moving' });
  assert.ok(free.includes(600), 'its own current slot must still be offered');
  assert.deepEqual(free, run([]), 'excluding it must leave the day exactly as if it were not booked');
});

test('v760 a longer duration genuinely has fewer free starts', () => {
  const hour = run([]);
  const long = run([], { duration: 180 });
  assert.deepEqual(long, [540], 'a three-hour visit fits only at 09:00 in a 09:00–12:00 day');
  assert.ok(long.length < hour.length);
});

test('v760 the amend panel is the customer flow markup wired to the same save path', () => {
  const render = app.slice(app.indexOf('function renderAppointmentDetails('), app.indexOf('function wireAppointmentActions('));
  // The customer booking flow's own steps, classes and copy — photos 3 & 4.
  assert.match(render, /Who would you like\?/);
  assert.match(render, /Pick a date &amp; time/);
  assert.match(render, /class="pf-choice appointment-amend-team-v760"/);
  assert.match(render, /class="pf-day-track"/);
  assert.match(render, /class="pf-slot-grid"/);
  assert.match(render, /\$\{day\.starts\.length\} free/);
  // ONE availability core: the picker calls the helper that calls availableCalendarStarts.
  assert.match(render, /amendAvailabilityDaysV760\(\{/);
  assert.match(render, /excludeAppointmentId:item\.id,scheduleFor:recordedSchedule/);
  assert.match(app, /return \{date:day,starts:availableCalendarStarts\(column,earliest,timing\)\}/);
  // The blind inputs are gone; the save path still reads the same three fields.
  assert.doesNotMatch(render, /<input id="appointmentEditDate" type="date"/);
  assert.doesNotMatch(render, /<input id="appointmentEditTime" type="time"/);
  for (const field of ['appointmentEditDate', 'appointmentEditTime', 'appointmentEditStaff']) {
    assert.match(render, new RegExp(`<input type="hidden" id="${field}"`), `${field} stays as the picker's output`);
  }
  const submit = app.slice(app.indexOf('editForm.onsubmit='), app.indexOf('function wireAppointmentActions('));
  assert.match(submit, /const starts=sgIso\(`\$\{\$\('appointmentEditDate'\)\.value\}T\$\{\$\('appointmentEditTime'\)\.value\}`\)/);
  assert.match(submit, /p_business:S\.biz\.id,p_appointment:item\.id,p_starts:starts,p_duration_minutes:editedDuration,p_staff:editedStaff,p_note:editedNote\|\|null/);
  assert.match(submit, /sb\.rpc\('reschedule_appointment_v48',\{\.\.\.request,p_idempotency_key:rescheduleAttempt\.key\}\)/);
  assert.match(submit, /data\?\.status==='conflict'/, 'the server clash rendering stays');
  // Duration and note stay editable; the two buttons keep their labels.
  assert.match(render, /id="appointmentEditDuration"/);
  assert.match(render, /id="appointmentEditNote"/);
  assert.match(render, /id="appointmentRescheduleSave">Confirm amendment</);
  assert.match(render, /id="appointmentRescheduleCancel">Keep current appointment</);
});
