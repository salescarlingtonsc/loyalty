import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

/* v291 (owner, annotated screenshot):
   1. "when press into bookings why it does not show me which business i want to choose?"
   2. "why the big chunk of box (to add date & time) takes up so much space, please reduce it
      to one liner."
   3. "why it only shows me 1 company for booking?" */

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const appJs = await read('app/app.js');
const indexHtml = await read('app/index.html');

function section(start, end) {
  const from = appJs.indexOf(start), to = appJs.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return appJs.slice(from, to);
}

const chooserSource = section('function customerBookingChooserV291', 'function customerBookingEmptyMarkupV183');
const chooser = new Function('esc', 'customerBookingBusinessLogoV195', `${chooserSource}
  return customerBookingChooserV291;`)(
  (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
  () => '<span class="customer-booking-logo"></span>');

test('every joined business appears — bookable ones book, the rest are honest, none are hidden', () => {
  const html = chooser([
    { business_slug: 'a', business_name: 'Cubbly', industry: 'Food & drink', bookingEnabled: true },
    { business_slug: 'b', business_name: 'AhXiang', industry: 'Food & drink', bookingEnabled: false },
  ]);
  assert.match(html, /data-repeat-booking data-business-slug="a"/, 'a bookable business books in one tap');
  assert.match(html, /href="#\/wallet\/b"/, 'a non-bookable business still leads somewhere useful');
  assert.match(html, /No online booking yet/, 'and says WHY it cannot be booked');
  assert.equal((html.match(/customer-booking-chip/g) || []).length >= 2, true);
});

test('more than one sector groups the chips under sector headings', () => {
  const html = chooser([
    { business_slug: 'a', business_name: 'Cubbly', industry: 'Food & drink', bookingEnabled: true },
    { business_slug: 'c', business_name: 'Hougang ABC', industry: 'Personal care', bookingEnabled: false },
  ]);
  assert.match(html, /customer-booking-sector[^>]*>Food &amp; drink</);
  assert.match(html, /customer-booking-sector[^>]*>Personal care</);
  // one sector stays flat — a heading over a single group is noise
  const flat = chooser([{ business_slug: 'a', business_name: 'Cubbly', industry: 'Food & drink', bookingEnabled: true }]);
  assert.doesNotMatch(flat, /customer-booking-sector/);
  // no joined businesses -> nothing rendered, never an empty card
  assert.equal(chooser([]), '');
});

test('merchant names and sectors are escaped and marked as merchant content', () => {
  const html = chooser([{ business_slug: 'x', business_name: '<img src=x>', industry: '<script>', bookingEnabled: true },
    { business_slug: 'y', business_name: 'B', industry: 'Other', bookingEnabled: false }]);
  assert.doesNotMatch(html, /<img src=x>/);
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /data-merchant-content/);
});

test('the chooser opens the Ongoing tab and the empty state no longer duplicates its buttons', () => {
  const paint = section('const paintBookings', 'async function renderCustomerMessages');
  assert.match(paint, /\$\{currentBookingTab==='bookings'\?customerBookingChooserV291\(allGroups\):''\}/);
  assert.match(paint, /customerBookingEmptyMarkupV183\(currentBookingTab,emptyCopy,currentBookingTab==='bookings'\?\[\]:allGroups\)/,
    'the chooser owns the book-with actions on the default tab');
  const grouping = section('function composeCustomerBookingGroups', 'function customerBookingRequestTabV178');
  assert.match(grouping, /group\.industry=String\(business\.industry\|\|''\)/);
});

test('the date filter is one 44px line, even on a phone', () => {
  assert.match(indexHtml, /\.customer-booking-filter input\[type="date"\]\{[^}]*width:auto;flex:1 1 0;max-width:126px/);
  assert.match(indexHtml, /@media\(max-width:520px\)\{\.customer-page-head\{flex-wrap:wrap\}\.customer-booking-filter\{width:100%;flex-wrap:nowrap/,
    'the phone keeps the filter on one line under the title — never the stacked box the owner circled');
  assert.match(indexHtml, /\.customer-booking-chips\{display:flex;gap:10px;overflow-x:auto/);
});
