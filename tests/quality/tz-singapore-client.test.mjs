/* nestly_tz-client (owner ruling 2026-09-02): every client-side date/time decision is Asia/
 * Singapore (GMT+8), never the browser's own zone or bare UTC. This file executes the real
 * helpers straight out of app/app.js (via `new Function`, the same discipline used by the
 * neighbouring f063/v279/v326 harnesses) against one fixed instant, so a regression that
 * reintroduces `new Date()`/`getHours()`/an ambient-zone Intl call fails a real assertion
 * instead of a source grep alone.
 *
 * Fixed instant used throughout: 2026-09-10T17:30:00Z == 2026-09-11T01:30:00+08:00.
 * That is deliberately just past midnight in Singapore while the UTC calendar day is still
 * the 10th — the exact class of moment where a device set to UTC (or anything west of SG)
 * disagrees with Singapore about what day it is, which is precisely what these fixes exist
 * to prevent.
 */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');

function slice(startMarker,endMarker){
  const start=app.indexOf(startMarker);
  assert.ok(start>=0,`missing start marker: ${startMarker}`);
  const end=app.indexOf(endMarker,start+startMarker.length);
  assert.ok(end>=0,`missing end marker: ${endMarker}`);
  return app.slice(start,end+endMarker.length);
}

const sgDateInputValueSrc=slice('const sgDateInputValue=(date=new Date())=>{','\n};');
const sgLocalInputValueSrc=slice('const sgLocalInputValue=instant=>{','\n};');
const sgHourSrc=app.match(/const sgHour=[^\n]+;/)?.[0];

test('the three helpers under test still exist in app.js',()=>{
  assert.ok(sgDateInputValueSrc,'sgDateInputValue must exist');
  assert.ok(sgLocalInputValueSrc,'sgLocalInputValue must exist');
  assert.ok(sgHourSrc,'sgHour must exist');
});

const {sgDateInputValue,sgLocalInputValue,sgHour}=Function(
  `${sgDateInputValueSrc}\n${sgLocalInputValueSrc}\n${sgHourSrc}\nreturn {sgDateInputValue,sgLocalInputValue,sgHour};`
)();

const FIXED_INSTANT='2026-09-10T17:30:00Z';
const FIXED_DATE=new Date(FIXED_INSTANT);
const SG_TODAY='2026-09-11'; // the calendar day that instant falls on in Asia/Singapore

test('sgLocalInputValue: an instant renders as its Singapore wall-clock datetime-local value (TZ-C2-03)',()=>{
  assert.equal(sgLocalInputValue(FIXED_INSTANT),'2026-09-11T01:30');
  // Never the UTC digits — that was the boundaryInputValue/sgInput bug class this replaces.
  assert.notEqual(sgLocalInputValue(FIXED_INSTANT),'2026-09-10T17:30');
});

test('sgDateInputValue: the Singapore calendar day for that instant is the 11th, not the UTC 10th',()=>{
  assert.equal(sgDateInputValue(FIXED_DATE),SG_TODAY);
});

test('sgHour: the Singapore wall-clock hour for that instant is 1am, not 17:00 UTC (TZ-C-03)',()=>{
  assert.equal(sgHour(FIXED_DATE),1);
});

test('DOB "not in the future" is a plain string compare against sgDateInputValue(), no new Date (TZ-C-01)',()=>{
  // Reproduces the exact expression both signup sites now use:
  //   birthDate > sgDateInputValue()
  // with sgDateInputValue() pinned to the fixed instant instead of the real clock.
  const rejectsAsFuture=birthDate=>birthDate>sgDateInputValue(FIXED_DATE);
  // Today in Singapore itself is not "in the future" — a signup on someone's day of birth
  // must be accepted, not rejected.
  assert.equal(rejectsAsFuture(SG_TODAY),false,'a birth date equal to SG-today must be accepted');
  // A day already past in Singapore is accepted too.
  assert.equal(rejectsAsFuture('2026-09-10'),false,'a birth date before SG-today must be accepted');
  // A day that has not started yet in Singapore is rejected.
  assert.equal(rejectsAsFuture('2026-09-12'),true,'a birth date after SG-today must be rejected');
});

test('both real signup sites compare strings against sgDateInputValue(), never new Date(...)>new Date()',()=>{
  assert.match(app,/if\(!signupBirthDate\|\|signupBirthDate>sgDateInputValue\(\)\)\{/,
    'customer self-signup DOB check must be the SG string compare');
  assert.match(app,/if\(!fullName\|\|!birthDate\|\|birthDate>sgDateInputValue\(\)\)\{/,
    'registration-profile DOB check must be the SG string compare');
});

test('boundaryInputValue and sgInput both delegate to sgLocalInputValue — one implementation (TZ-C-02)',()=>{
  assert.match(app,/const boundaryInputValue=\(value\)=>value\?sgLocalInputValue\(value\):'';/);
  assert.match(app,/const sgInput=iso=>sgLocalInputValue\(iso\);/);
  assert.doesNotMatch(app,/Kuala_Lumpur/,'no client date helper may anchor to a non-SG zone id');
});

test('customerDaypartV343 reads the hour via sgHour, not the browser-local hour (TZ-C-03)',()=>{
  assert.match(app,/function customerDaypartV343\(now=new Date\(\)\)\{\s*\n\s*const hour=sgHour\(now\);/);
});

test('formatPasskeyDate delegates to walletDate — Singapore zone, not the ambient locale (TZ-C-04)',()=>{
  assert.match(app,/const formatPasskeyDate=value=>walletDate\(value\)\|\|'Date unavailable';/);
});

test('the 1-month and 5-year grow-history windows are derived from the SG calendar day, not new Date() field math (TZ-C-05)',()=>{
  assert.match(app,/const growHistoryDefaultFromV382=Date\.parse\(`\$\{shiftSgDateInput\(sgDateInputValue\(\),-30\)\}T00:00:00\+08:00`\);/);
  assert.match(app,/const growHistoryCutoffV375=\(\(\)=>\{\s*\n\s*const match=sgDateInputValue\(\)\.match/);
});

test('source guard: no ambient-zone/locale date APIs remain in app.js (regression net for this whole wave)',()=>{
  assert.doesNotMatch(app,/getHours\(\)/,'no code may read the hour via the browser-local clock');
  assert.doesNotMatch(app,/Kuala_Lumpur/,'no code may anchor Singapore time to a different zone id');
  assert.doesNotMatch(app,/new Intl\.DateTimeFormat\(undefined/,'no Intl formatter may run under the ambient locale/zone');
});

test('growth-offers.js safeDate is Singapore-anchored, not the ambient device zone (TZ-C2-01, TZ-C2-11)',()=>{
  const growthOffers=readFileSync(new URL('../../app/growth-offers.js',import.meta.url),'utf8');
  assert.match(growthOffers,/const safeDate=value=>\{[\s\S]*?timeZone:'Asia\/Singapore'[\s\S]*?\};/,
    'safeDate must pass an explicit Asia/Singapore timeZone to toLocaleString');
});

test('the booking-fingerprint edge helper anchors a zoneless preferred/proposed time to +08:00, and leaves zoned values alone (TZ-E-01, TZ-E-02)',()=>{
  const security=readFileSync(new URL('../../supabase/functions/_shared/security.ts',import.meta.url),'utf8');
  const src=security.match(/function sgAnchoredIso\(value: string\): string \{[\s\S]*?\n\}/)?.[0];
  assert.ok(src,'sgAnchoredIso must exist');
  // Compile the TS body as plain JS by stripping its two type annotations — the body itself
  // uses no TypeScript syntax.
  const jsSrc=src.replace('function sgAnchoredIso(value: string): string {','function sgAnchoredIso(value){');
  const {sgAnchoredIso}=Function(`${jsSrc}\nreturn {sgAnchoredIso};`)();
  // A zoneless datetime-local value is read as Singapore time.
  assert.equal(sgAnchoredIso('2026-09-11T01:30'),new Date('2026-09-10T17:30:00Z').toISOString());
  // A value that already carries an explicit zone is left untouched.
  assert.equal(sgAnchoredIso('2026-09-11T01:30:00Z'),new Date('2026-09-11T01:30:00Z').toISOString());
  assert.equal(sgAnchoredIso('2026-09-11T09:30:00+08:00'),new Date('2026-09-11T09:30:00+08:00').toISOString());
  assert.match(security,/preferred: sgAnchoredIso\(String\(input\.preferred\)\),/);
  assert.match(security,/proposed: input\.proposed \? sgAnchoredIso\(String\(input\.proposed\)\) : null,/);
});
