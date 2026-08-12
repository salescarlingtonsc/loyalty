import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

/* v294 (owner: "Why only one company showed when i already enable qrcode?"): the "Customer
   booking" checkbox is only one of the conditions customers' Book buttons depend on — at least
   one active service must be shown on the booking page. The settings screen must SAY that at
   the moment it bites, instead of leaving the owner to discover it from a customer. */

const appJs = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

function section(start, end) {
  const from = appJs.indexOf(start), to = appJs.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start}`);
  return appJs.slice(from, to);
}

test('the inert-booking warning exists, names the cause and the next step', () => {
  assert.match(appJs, /id="customerBookingInertWarning"[^>]*hidden/);
  assert.match(appJs, /no active service is shown on your booking page/);
  assert.match(appJs, /Show on booking page/);
});

test('the warning tracks the real dependency and stays in lockstep with the checkbox', () => {
  const wiring = section("const capabilityResult=await sb.rpc('business_get_customer_capabilities_v89'", 'async function loadSi');
  assert.match(wiring, /\.eq\('active',true\)\.eq\('show_on_booking_page',true\)/,
    'the count matches the exact predicate customer_get_business_actions_v89 gates on');
  assert.match(wiring, /warning\.hidden=!\(\$\('customerBookingEnabled'\)\.checked&&bookableServiceCount===0\)/,
    'shown only when the box is ticked AND nothing is bookable');
  assert.match(wiring, /result\.error\?null:Number\(result\.count\)\|\|0,\(\)=>null/,
    'a failed count stays silent rather than crying wolf');
  assert.match(wiring, /addEventListener\('change',refreshBookingInertWarningV294\)/);
  const saves = wiring.match(/refreshBookingInertWarningV294\(\)/g) || [];
  assert.ok(saves.length >= 2, 'refreshed on load and after save');
});
