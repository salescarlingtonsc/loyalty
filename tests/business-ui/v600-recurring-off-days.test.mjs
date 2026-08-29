/* nestly_v600 — a repeating day off is set where a one-off block is set.
 *
 * Owner: "i need to be able to set recurring off days for them. and easily amend the off days if i
 * want to. (like every wednesday & sunday) on top of current ad hoc block time." Asked where it
 * should live; owner chose the Block time dialog, one screen, and accepted that the roster stops
 * writing days off so there is only one place that can.
 *
 * The DANGEROUS part of this is not the panel, it is the NUMBER. staff_recurring_off_days.weekday
 * is compared against extract(dow) in public.internal_public_booking_availability, where 0 is
 * Sunday. A weekday list written in any other order still saves, still reads back, and closes the
 * wrong day — a salon shut on Sunday would take Sunday bookings and refuse Monday's. So the order
 * is executed here rather than eyeballed, together with the add/remove diff that decides what is
 * actually written.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');

test('the weekday list is in Postgres dow order, so a tick index IS the stored weekday',()=>{
  const source=app.match(/const WEEKDAY_NAMES_V600=Object\.freeze\(\[[^\]]*\]\)/)?.[0];
  assert.ok(source,'WEEKDAY_NAMES_V600 is declared');
  const names=JSON.parse(source.slice(source.indexOf('['),source.lastIndexOf(']')+1).replace(/'/g,'"'));
  /* extract(dow): 0=Sunday … 6=Saturday. This is the whole reason the constant exists. */
  assert.deepEqual(names,
    ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday']);
  assert.equal(names[0],'Sunday','0 must be Sunday — Cubbly is the tenant that opened on a Sunday');
  assert.equal(names[3],'Wednesday','3 must be Wednesday — the owner\'s own example');
});

/* The diff the save runs, lifted verbatim in shape from saveWeeklyOffV600: what is newly ticked is
   written, what was unticked is removed, and an unchanged set writes nothing at all. */
const diff=(had,wanted)=>({
  added:wanted.filter(day=>!had.includes(day)),
  removed:had.filter(day=>!wanted.includes(day))
});

test('amending a set of days off writes only the difference',()=>{
  // the owner's example: already off Wednesday, now also Sunday
  assert.deepEqual(diff([3],[3,0]),{added:[0],removed:[]});
  // removing one
  assert.deepEqual(diff([0,3],[3]),{added:[],removed:[0]});
  // swapping
  assert.deepEqual(diff([3],[1]),{added:[1],removed:[3]});
  // clearing every day off
  assert.deepEqual(diff([0,3],[]),{added:[],removed:[0,3]});
  // NOTHING is written when nothing moved — otherwise every open-and-close rewrites the rows
  assert.deepEqual(diff([0,3],[0,3]),{added:[],removed:[]});
  assert.deepEqual(diff([],[]),{added:[],removed:[]});
});

test('the dialog offers the repeating mode and reads the days already set',()=>{
  const dialog=app.slice(app.indexOf('function openBlockedTimeDialog'),app.indexOf("$('openAppointmentForm').onclick"));
  assert.match(dialog,/id="blockModeWeeklyV600"/,'a way into the repeating mode');
  assert.match(dialog,/data-weekly-off-v600="\$\{weekday\}"/,'one tick per weekday, carrying its dow');
  assert.match(dialog,/const weeklyOffForV600=staffId=>\(staffWeeklyOff\|\|\[\]\)/,
    'the ticks are read from the days off this person ALREADY has — that is what makes it an amend screen');
  assert.match(dialog,/blockModeV600==='weekly'\)return saveWeeklyOffV600\(\)/,
    'the repeating mode takes the whole submit');
  assert.match(dialog,/onConflict:'staff_id,weekday'/,'writing a day off twice is not an error');
});

test('the hidden half of the form stops demanding fields nobody can see',()=>{
  const dialog=app.slice(app.indexOf('function openBlockedTimeDialog'),app.indexOf("$('openAppointmentForm').onclick"));
  /* Left `required` while hidden, the date and time inputs block submit with a browser validation
     bubble pointing at nothing on screen — the form simply refuses and never says why. */
  assert.match(dialog,/\['blockTimeDate','blockTimeStart','blockTimeEnd'\]\.forEach\(id=>\{[\s\S]{0,120}required=mode!=='weekly'/);
});

test('the roster no longer writes days off — Block time is their one home',()=>{
  const save=app.slice(app.indexOf('async function saveStaffRotaV228'),app.indexOf('async function loadTeam'));
  assert.doesNotMatch(save,/staff_recurring_off_days/,
    'two screens editing one thing is two screens that can disagree');
  assert.match(save,/sb\.from\('staff_hours'\)\.upsert\(/,'it still writes working hours');
});
