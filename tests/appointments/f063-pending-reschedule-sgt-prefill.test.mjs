import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

/* F063: the owner's "Change time" (List-tab pending-request card, V329) and
   "Change time / staff" (calendar-tile dialog, V330) reschedule forms used to
   seed their datetime-local input with `(r.preferred_at||'').slice(0,16)` —
   the raw UTC digits from PostgREST's timestamptz string. In prod (session
   TimeZone=UTC) a booking preferred for 10:30 SGT reads back as
   '...T02:30:00+00:00', so the input showed 02:30 and "Move & confirm" sent
   that same 02:30 straight through sgIso() (which anchors it to +08:00),
   moving the booking 8 hours earlier than the customer asked for.
   Fix: seed both inputs with sgInput(r.preferred_at) — the same UTC-instant
   -> SGT-local-string helper every other datetime-local prefill on this
   surface already uses (see app.js:44553, 44616, 44649, 44893). */

const root=new URL('../../',import.meta.url);
const app=await readFile(new URL('app/app.js',root),'utf8');

/* nestly_tz-client: sgInput no longer re-derives SGT itself — it delegates to the single
   canonical instant->datetime-local helper, sgLocalInputValue (declared next to sgIso), so
   this harness pulls that source in too rather than eval'ing sgInput in isolation. */
const sgInputSource=app.match(/const sgInput=iso=>[^\n]+;/)?.[0];
const sgIsoSource=app.match(/const sgIso=v=>[^\n]+;/)?.[0];
const sgLocalInputValueSource=app.match(/const sgLocalInputValue=instant=>\{[\s\S]*?\n\};/)?.[0];

test('sgInput and sgIso helpers exist in app.js',()=>{
  assert.ok(sgInputSource,'sgInput helper must exist');
  assert.ok(sgIsoSource,'sgIso helper must exist');
  assert.ok(sgLocalInputValueSource,'sgLocalInputValue helper must exist');
});

const {sgInput,sgIso}=Function(`${sgIsoSource}\n${sgLocalInputValueSource}\n${sgInputSource}\nreturn {sgInput,sgIso};`)();

test('a stored UTC instant pre-fills as its Singapore local wall time (F063)',()=>{
  // 2026-09-10T02:30:00Z is 10:30 in Singapore (+08:00).
  assert.equal(sgInput('2026-09-10T02:30:00Z'),'2026-09-10T10:30');
  // The same fixture as the raw-slice bug would have produced: the buggy
  // code showed the UTC digits (02:30) verbatim instead of the SGT ones.
  assert.notEqual(sgInput('2026-09-10T02:30:00Z'),'2026-09-10T02:30');
});

test('Move & confirm sends back the exact same instant it read (round-trip)',()=>{
  const stored='2026-09-10T02:30:00.000Z';
  const local=sgInput(stored);
  const sentBack=sgIso(local);
  assert.equal(new Date(sentBack).getTime(),new Date(stored).getTime());
});

test('both pending-reschedule datetime-local inputs pre-fill via sgInput, not a raw UTC slice',()=>{
  assert.match(app,/id="pendingRescheduleTimeV329-\$\{esc\(r\.id\)\}" type="datetime-local" value="\$\{esc\(r\.preferred_at\?sgInput\(r\.preferred_at\):''\)\}"/,
    'List-tab pending-request card (V329) must seed the field from sgInput(r.preferred_at)');
  assert.match(app,/id="pendingTileTimeV330" type="datetime-local" value="\$\{esc\(row\.preferred_at\?sgInput\(row\.preferred_at\):''\)\}"/,
    'calendar-tile dialog (V330) must seed the field from sgInput(row.preferred_at)');
  assert.doesNotMatch(app,/type="datetime-local" value="\$\{esc\(\(r\.preferred_at\|\|''\)\.slice\(0,16\)\)\}"/,
    'no pending-reschedule input may fall back to the raw UTC .slice(0,16) prefill');
  assert.doesNotMatch(app,/type="datetime-local" value="\$\{esc\(\(row\.preferred_at\|\|''\)\.slice\(0,16\)\)\}"/,
    'no pending-reschedule input may fall back to the raw UTC .slice(0,16) prefill');
});

test('both reschedule submit handlers send sgIso(timeInput.value) unchanged',()=>{
  assert.match(app,/const preferred=sgIso\(timeInput\.value\);[\s\S]{0,400}staff_reschedule_and_confirm_booking_request_v329[\s\S]{0,80}p_preferred:preferred/);
  const occurrences=app.match(/const preferred=sgIso\(timeInput\.value\);/g)||[];
  assert.equal(occurrences.length,2,'both the List-tab and tile-modal submit handlers must convert via sgIso');
});
