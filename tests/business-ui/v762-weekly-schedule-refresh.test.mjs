/* nestly_v762 — the screen must agree with the database after a weekly save.
 *
 * Owner, 2026-09-05, with a screenshot of the Block time dialog: "i tried to apply block time >
 * nothing happened." The save had in fact worked — production held one recurring off day and seven
 * 12:00-13:00 breaks for that teammate, all written in a single transaction. What had NOT happened
 * was any re-read: staffWeeklyOff and staffWeeklyBreaks were page-load consts, fetched once by
 * appointmentsPage and never refreshed, so reopening the dialog painted the pre-save state ("No
 * repeating days off yet") and the calendar kept drawing the old week until a full page reload.
 *
 * That is indistinguishable from a save that silently failed, which is the worst thing a schedule
 * screen can be: an owner cannot tell whether their staff are bookable through lunch or not.
 *
 * The defect class is "a writer refreshes nothing", not "this one dialog". So the refresh helper is
 * EXECUTED here against stubs — including the failure path, where keeping the last known rows
 * matters more than blanking them — rather than grepped for.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

/* Lift the real helper out of app.js by brace-matching, so this test runs the shipped code rather
   than a paraphrase of it. */
const extract = (declaration) => {
  const start = app.indexOf(declaration);
  assert.notEqual(start, -1, `${declaration} is declared in app/app.js`);
  let depth = 0, index = app.indexOf('{', start);
  const open = index;
  for (; index < app.length; index += 1) {
    if (app[index] === '{') depth += 1;
    else if (app[index] === '}') { depth -= 1; if (depth === 0) break; }
  }
  return app.slice(open, index + 1);
};

const OFF_ROWS = [{staff_id: 's1', weekday: 0}];
const BREAK_ROWS = [0, 1, 2, 3, 4, 5, 6].map((weekday) => (
  {staff_id: 's1', weekday, starts_at: '12:00:00', ends_at: '13:00:00'}
));

/* Runs the extracted body with a stubbed reader. `outcome` decides what each read returns. */
const runRefresh = async (outcome, seed) => {
  const body = extract('const refreshWeeklyScheduleV762=async()=>');
  const scope = {
    staffWeeklyOff: seed.off,
    staffWeeklyBreaks: seed.breaks,
    S: {biz: {id: 'biz-1'}},
    asked: [],
  };
  const table = (name) => {
    scope.asked.push(name);
    const builder = {
      select: () => builder, eq: () => builder, order: () => builder,
      table: name,
    };
    return builder;
  };
  const sb = {from: table};
  const fetchAllRowsResult = async (build) => {
    const builder = build();
    return outcome(builder.table);
  };
  const fn = new Function('sb', 'fetchAllRowsResult', 'S', 'state', `
    let staffWeeklyOff = state.off, staffWeeklyBreaks = state.breaks;
    const refreshWeeklyScheduleV762 = async () => ${body};
    return refreshWeeklyScheduleV762().then(() => ({staffWeeklyOff, staffWeeklyBreaks}));
  `);
  const result = await fn(sb, fetchAllRowsResult, scope.S, {off: seed.off, breaks: seed.breaks});
  return {...result, asked: scope.asked};
};

test('a successful refresh replaces both weekly arrays with what the database now holds', async () => {
  const {staffWeeklyOff, staffWeeklyBreaks, asked} = await runRefresh(
    (name) => ({data: name === 'staff_recurring_off_days' ? OFF_ROWS : BREAK_ROWS, error: null}),
    {off: [], breaks: []},
  );
  // The exact state the owner saved and could not see.
  assert.deepEqual(staffWeeklyOff, OFF_ROWS, 'the Sunday off day is now readable by the dialog');
  assert.equal(staffWeeklyBreaks.length, 7, 'and all seven lunch breaks reach the calendar');
  assert.deepEqual(
    asked.slice().sort(),
    ['staff_recurring_breaks', 'staff_recurring_off_days'],
    'both tables are re-read — refreshing only one leaves half the dialog lying',
  );
});

test('a failed refresh keeps the last known rows rather than blanking the week', async () => {
  const {staffWeeklyOff, staffWeeklyBreaks} = await runRefresh(
    () => ({data: null, error: {message: 'network'}}),
    {off: OFF_ROWS, breaks: BREAK_ROWS},
  );
  /* The write already succeeded. Emptying these on a failed READ would redraw the calendar as
     "nobody has any breaks" — the precise lie this migration of behaviour exists to end. */
  assert.deepEqual(staffWeeklyOff, OFF_ROWS);
  assert.equal(staffWeeklyBreaks.length, 7);
});

test('the weekly arrays are rebindable, not page-load constants', () => {
  assert.match(
    app,
    /let staffWeeklyOff=staffWeeklyOffLoaded\|\|\[\],staffWeeklyBreaks=staffWeeklyBreaksLoaded\|\|\[\]/,
    'const bindings are what made the stale read unfixable in place',
  );
});

test('the save re-reads before it closes and redraws', () => {
  const save = extract('const saveWeeklyOffV600=async()=>');
  const refresh = save.indexOf('await refreshWeeklyScheduleV762()');
  const redraw = save.indexOf('close();loadCalendar()');
  assert.ok(refresh > -1, 'the successful save refreshes');
  assert.ok(redraw > -1, 'and still redraws the calendar');
  assert.ok(refresh < redraw, 'the refresh must land BEFORE the redraw — loadCalendar paints from these arrays');
});

test('a save with nothing changed says so instead of closing in silence', () => {
  const save = extract('const saveWeeklyOffV600=async()=>');
  assert.match(
    save,
    /if\(!added\.length&&!removed\.length&&!addedBreaks\.length&&!removedBreaks\.length\)\{\s*close\(\);toast\('Weekly schedule unchanged'\);return;\s*\}/,
    'a silent close reads exactly like a failed save',
  );
});
