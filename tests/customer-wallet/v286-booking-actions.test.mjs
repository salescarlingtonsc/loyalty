import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const appJs = await read('app/app.js');
const indexHtml = await read('app/index.html');

function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

const bookings = section(appJs, 'async function renderCustomerBookings(){', 'async function renderCustomerMessages(){');
const portalUpcoming = section(appJs, 'async function portalAppointmentChangesEnabledV286', 'async function renderPortal(slug)');

/* ---------------------------------- 1 · the Bookings page can actually change a booking */

const tabs = section(appJs, 'const CANCELLED_CUSTOMER_BOOKING_STATUSES_V178', 'function customerBookingRangeBoundV195');
const changeAction = new Function(`${tabs}
  return customerBookingChangeActionV286;`)();

const ongoingGroup = { business_slug: 'spa-glow', appointmentChangesEnabled: true };
const upcoming = { appointment_id: 'a1', status: 'booked', starts_at: new Date(Date.now() + 864e5).toISOString() };

test('an upcoming booked appointment offers Change, under both of the wallet gates', () => {
  assert.equal(changeAction(ongoingGroup, upcoming, true), true);
  // The platform feature and the business's own appointment_changes setting both have a veto.
  assert.equal(changeAction(ongoingGroup, upcoming, false), false);
  assert.equal(changeAction({ ...ongoingGroup, appointmentChangesEnabled: false }, upcoming, true), false);
  assert.equal(changeAction({ ...ongoingGroup, business_slug: '' }, upcoming, true), false);
  // Nothing to act on: a past visit, a cancelled one, or a row with no appointment identity.
  assert.equal(changeAction(ongoingGroup, { ...upcoming, starts_at: '2020-01-01T00:00:00Z' }, true), false);
  assert.equal(changeAction(ongoingGroup, { ...upcoming, status: 'cancelled' }, true), false);
  assert.equal(changeAction(ongoingGroup, { ...upcoming, status: 'completed' }, true), false);
  assert.equal(changeAction(ongoingGroup, { ...upcoming, appointment_id: '' }, true), false);
});

test('the Bookings page renders and wires the replacing Reschedule control', () => {
  /* nestly_v509 (owner photo 3): the ongoing row's control is Reschedule, and reschedule means
     REPLACE — customer_reschedule_appointment_v508 cancels the booked appointment and files a
     fresh pending request in one transaction. The old v286 "Change" button (a v33 amendment the
     appointment waited on) is gone from these rows; the wallet sheet's cancel path keeps v33. */
  assert.match(appJs, /const rescheduleV508=group\.bookingEnabled===true&&!!group\.business_slug&&!!item\.appointment_id\s*\n\s*&&String\(item\.status\|\|''\)==='booked'&&tab==='bookings';/);
  assert.match(appJs, /const action=rescheduleV508\s*\n\s*\?`<button class="btn ghost sm" type="button" data-reschedule-v508="\$\{esc\(item\.appointment_id\)\}" data-business-slug="\$\{esc\(group\.business_slug\)\}" data-starts-at="\$\{esc\(item\.starts_at\|\|''\)\}">Reschedule<\/button>`/);
  assert.doesNotMatch(appJs, /class="btn ghost sm walletChange" type="button" data-id="\$\{esc\(item\.appointment_id\)\}"[^`]*>Change</,
    'the amendment-style Change button must not return to the Bookings rows');
  // The page wires every Reschedule button to the replace sheet, and a sent request repaints.
  assert.match(bookings, /data-reschedule-v508\]'\)\.forEach\(button=>\{/);
  assert.match(bookings, /openRescheduleReplaceSheetV508\(\{/);
  assert.match(bookings, /onDone:\(\)=>renderCustomerBookings\(\)/);
  // The sheet says what Send does before it is pressed, and calls the v508 replace RPC.
  assert.match(appJs, /Your current appointment is removed straight away\./);
  assert.match(appJs, /sb\.rpc\('customer_reschedule_appointment_v508',\{\s*p_business_slug:businessSlug,p_appointment:appointmentId/);
  const changesFeature=bookings.includes("const changesFeatureEnabled=context.features.customer_actions===true;");
  assert.equal(changesFeature, true, 'the customer_actions feature flag is still read for the wallet cancel path');
  assert.match(bookings, /wireWalletAppointmentActions\('',\{onDone:\(\)=>renderCustomerBookings\(\)\}\)/);
  assert.match(bookings, /appointment_changes_enabled:!response\.error&&response\.data\?\.appointment_changes\?\.enabled===true/);
  const compose = section(appJs, 'function composeCustomerBookingGroups', 'const CUSTOMER_BOOKING_TABS_V178');
  assert.match(compose, /group\.appointmentChangesEnabled=card\?\.appointment_changes_enabled===true;/);
  assert.match(compose, /appointmentChangesEnabled:false/, 'a business that never reported the flag stays false');
  // The control is a real 44px target, not a decorative pill.
  assert.match(indexHtml, /\.btn\.sm\{[^}]*min-height:44px/);
});

/* ---------------------------------- 2 · the load cannot hang for ever */

test('every Bookings read carries the customer deadline helper', () => {
  for (const name of ['customer_get_wallet', 'customer_list_programmes_v89', 'customer_get_booking_requests',
    'customer_get_programme_selector_media_v96', 'customer_get_business_actions_v89', 'customer_get_appointments_page']) {
    assert.match(bookings, new RegExp(`customerRpc\\('${name}'`), `${name} must carry a deadline`);
  }
  assert.doesNotMatch(bookings, /sb\.rpc\(/, 'no unbounded call may remain on the Bookings route');
  assert.match(portalUpcoming, /customerRpc\('customer_get_appointments_page'/);
  assert.doesNotMatch(portalUpcoming, /sb\.rpc\(/);
});

/* ---------------------------------- 3 · the partial-failure notice names what is missing */

test('the six computed partial-failure messages are rendered, not just counted', () => {
  assert.match(bookings, /partialMessages\.map\(message=>`<li>\$\{esc\(message\)\}<\/li>`\)\.join\(''\)/);
  assert.match(bookings, /Some booking info didn’t load\./, 'the summary line stays as the heading of the list');
  for (const message of ['Confirmed appointments could not be discovered from your programmes.',
    'Pending and waitlisted booking requests are temporarily unavailable.',
    'More active requests could not be loaded. Try again.']) {
    assert.ok(bookings.includes(message), `still computed: ${message}`);
  }
});

/* ---------------------------------- 4 · the portal honours the business's own setting */

test('the portal Change button is gated on appointment_changes, and fails closed', () => {
  assert.match(portalUpcoming, /const actions=await customerRpc\('customer_get_business_actions_v89',\{p_business:businessId\}\);/);
  assert.match(portalUpcoming, /return !actions\.error&&actions\.data\?\.appointment_changes\?\.enabled===true;/);
  assert.match(portalUpcoming, /if\(error\)return false;/, 'an unreadable capability must hide the control');
  assert.match(portalUpcoming, /catch\(_error\)\{return false\}/);
  assert.match(portalUpcoming, /changesEnabled\?`<button class="btn ghost sm walletChange"[^`]*`:'<span class="muted small">Contact the business to change this<\/span>'/);
});

/* ---------------------------------- 5 · the guest manage panel tells the truth after a change */

test('a guest cancellation disables its buttons, keeps its submission id and repaints', () => {
  const cancel = section(appJs, 'const mCancelHandler=async()=>{', 'const mRescheduleHandler=async()=>{');
  const reschedule = section(appJs, 'const mRescheduleHandler=async()=>{', '  draw();');
  for (const block of [cancel, reschedule]) {
    assert.match(block, /manageChangeBusyV286\(true\);/, 'both buttons go busy for the await');
    assert.match(block, /catch\(error\)\{manageChangeBusyV286\(false\);return toast\(humanErrorV295\(error,'[^']+'\)\)\}/);
    assert.match(block, /manageChangeSettledV286\(data\);/);
    assert.doesNotMatch(block, /changeAttempt=null;/,
      'clearing the attempt let a repeat tap mint a second submission_id and duplicate the request');
  }
  const settled = section(appJs, 'const manageChangeSettledV286=data=>{', '  const mCancelHandler=async()=>{');
  assert.match(settled, /\$\('mfind'\)\?\.click\(\);/, 'the row repaints from a fresh lookup, not from hope');
  /* v294: the buttons carry real listeners attached per repaint — no inline onclick, no
     window globals (minifier-safe, and survives a CSP without 'unsafe-inline'). */
  assert.match(appJs, /<button class="btn ghost sm" id="mcancel" type="button">/);
  assert.match(appJs, /<button class="btn sm" id="mresched" type="button">/);
  assert.match(appJs, /\$\('mcancel'\)\?\.addEventListener\('click',mCancelHandler\)/);
  assert.match(appJs, /\$\('mresched'\)\?\.addEventListener\('click',mRescheduleHandler\)/);
});

/* ---------------------------------- 6 · one surface, one timezone */

test('the guest booking lookup prints Singapore time like every other date here', () => {
  assert.match(appJs, /\$\('mlist'\)\.innerHTML=`<div style="padding:10px 0"><b>\$\{esc\(walletDate\(when,true\)\)\|\|'Time pending'\}<\/b>/);
  assert.doesNotMatch(appJs, /new Date\(when\)\.toLocaleString\(\)/,
    'an ISO instant formatted in the device zone showed a different hour than the confirmation card');
  assert.match(appJs, /function walletDate\(value,withTime=false\)\{[\s\S]*timeZone:'Asia\/Singapore'/);
});

/* ---------------------------------- 7 · "Book again" really does rebook the same person */

test('the cached team member is resolved to a roster id instead of a field that never existed', () => {
  assert.doesNotMatch(appJs, /\$\('teamName'\)/, 'the portal has no element with that id — the write was dead');
  const portal = section(appJs, 'const staffMember=id=>bookableStaff.find', 'const availabilityKey=');
  assert.match(portal, /if\(repeatPreference\?\.staffName&&staffChoice\)\{/);
  assert.match(portal, /matches\.length===1\)selStaff=matches\[0\]\.id;/,
    'two team members with the same name must not silently pick one');
  assert.match(portal, /staffForService\(\)\.filter\(member=>String\(member\?\.name\|\|''\)\.trim\(\)\.toLowerCase\(\)===wanted\)/);
});
