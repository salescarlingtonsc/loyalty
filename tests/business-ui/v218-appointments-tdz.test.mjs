/* V218 — regression guard for a crash I shipped in V217.
   V217 opened the booking form on arrival with
     openNewAppointmentForm({date:addDays(todaySg,dayOffset)})
   but `addDays` is a `const` declared LATER in the same function. That line runs during the
   synchronous render, before the binding exists, so it threw
     "Cannot access 'addDays' before initialization"
   and took the whole Appointments page down — which is what the owner reported as the header's
   New appointment button "still not working".

   Why nothing caught it: node --check cannot see a temporal-dead-zone error; the
   undeclared-identifier guard cannot either, because the declaration DOES exist, just later;
   and no test executes this page. A general "used before declared" scan was attempted and
   abandoned — separating render-time statements from nested function bodies needs a real
   parser, and the heuristic version produced enough false positives to be untrustworthy.
   This guard is narrow and precise instead: it pins the fixed call, and it fails on the exact
   code that shipped. The general class remains uncovered; executing the page in a test is the
   only durable answer and is a larger piece of work. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const lines = app.split('\n');

const pageStart = lines.findIndex((l) => l.startsWith('async function appointmentsPage('));
assert.notEqual(pageStart, -1, 'appointmentsPage must exist');
const pageEnd = lines.findIndex((l, i) => i > pageStart && /^(?:async\s+)?function\s/.test(l));
const body = lines.slice(pageStart, pageEnd === -1 ? lines.length : pageEnd);

test('V218 arriving with the form requested computes no date at render time', () => {
  const open = body.find((l) => l.includes('if(apptOpenFormV217&&!apptPrefillClient)'));
  assert.ok(open, 'the header deep-link must still open the form');
  // No date at all: #ad already carries todaySg from its own markup, so nothing needs computing
  // before the page's own date helpers exist.
  assert.match(open, /openNewAppointmentForm\(\{\}\)/);
  assert.doesNotMatch(open, /addDays/,
    'addDays is declared further down appointmentsPage and throws if called during the render');
});

test('V218 addDays is still declared after the render path, so the guard stays meaningful', () => {
  const declLine = body.findIndex((l) => /\bconst\s+addDays\s*=/.test(l));
  const useLine = body.findIndex((l) => l.includes('if(apptOpenFormV217&&!apptPrefillClient)'));
  assert.notEqual(declLine, -1, 'addDays must still be a const in appointmentsPage');
  assert.ok(useLine < declLine,
    'if addDays were moved above the render path this test would stop proving anything — ' +
    'update it deliberately rather than letting it pass vacuously');
});
