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

/* v326 (owner: crossed out "Book with", circled "here put filter to search company name"): the
   chooser gained a live search field over the same chips, which needs CUI.icon for its magnifier —
   stubbed here exactly as every other isolated markup test stubs it. */
const chooserSource = section('function customerBookingChooserV291', 'function customerBookingEmptyMarkupV183');
/* nestly_v549: the chooser now classifies each business through customerBusinessCategoryV122 so
   the search can be reached by sector words. The REAL function is injected, not a stub — the whole
   point of reusing it is that the chips and the category headings share one vocabulary, and a stub
   would test a vocabulary that ships nowhere. */
const categorySource = section('function customerBusinessCategoryV122', '/* nestly_v395: the category order');
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const built = new Function('esc', 'CUI', 'customerBookingBusinessLogoV195', `${categorySource}
  ${chooserSource}
  return {customerBookingChooserV291, wireCustomerBookingSearchV326, customerBusinessCategoryV122};`)(
  esc, { icon: () => '' }, () => '<span class="customer-booking-logo"></span>');
const chooser = built.customerBookingChooserV291;

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

/* Top-20 #19 moved this lock, it did not lift it: the filter is still ONE 44px line under the
   title, but that line is now a chip that says what it is filtering, and the two date fields it
   used to be moved into the panel the chip opens. */
test('the date filter is one 44px line, even on a phone', () => {
  assert.match(indexHtml, /\.customer-datesheet-chip-v3\{[^}]*min-height:44px[^}]*border-radius:999px/);
  assert.match(indexHtml, /@media\(max-width:520px\)\{\.customer-page-head\{flex-wrap:wrap\}\.customer-datesheet-wrap-v3\{width:100%;align-items:stretch\}\.customer-datesheet-chip-v3\{width:100%/,
    'the phone keeps the filter on one line under the title — never the stacked box the owner circled');
  assert.match(indexHtml, /\.customer-datesheet-v3\[hidden\]\{display:none\}/,
    'the panel is a grid, so it needs its own hidden rule or the attribute does nothing');
  assert.match(indexHtml, /\.customer-booking-chips\{display:flex;gap:10px;overflow-x:auto/);
});

/* nestly_v549 (owner: "search please allow for keywords search like if type salon or spa or
   facial or hair etc"). These EXECUTE the shipped filter against a stubbed DOM rather than
   grepping it, because the interesting part is which businesses survive a query — a regex over
   the source cannot tell you that "salon" reaches a business whose sector says "beauty". */
function runSearch(groups, query) {
  const html = built.customerBookingChooserV291(groups);
  const items = [...html.matchAll(/data-booking-search-item ([^>]*?)>/g)].map((match) => {
    const attrs = match[1];
    const pick = (name) => (attrs.match(new RegExp(`${name}="([^"]*)"`)) || [, ''])[1]
      .replace(/&amp;/g, '&').replace(/&#39;/g, "'").replace(/&quot;/g, '"');
    return { dataset: {
      bookingSearchName: pick('data-booking-search-name'),
      bookingSearchTerms: pick('data-booking-search-terms'),
      bookingSearchCategory: pick('data-booking-search-category'),
      /* nestly_v571: the recency stamp the empty-query default sorts on. */
      bookingLastAt: pick('data-booking-last-at'),
    }, hidden: false };
  });
  assert.equal(items.length, groups.length, 'every business rendered a searchable chip');
  const status = { hidden: true, textContent: '' };
  let handler = null;
  const input = { value: '', addEventListener: (_event, fn) => { handler = fn; } };
  built.wireCustomerBookingSearchV326({
    querySelector: (sel) => (sel === '#customerBookingSearch' ? input
      : sel === '#customerBookingSearchStatus' ? status : null),
    querySelectorAll: (sel) => (sel === '[data-booking-search-item]' ? items : []),
  });
  input.value = query; handler();
  return { shown: items.filter((item) => !item.hidden).map((item) => item.dataset.bookingSearchName), status };
}

/* nestly_v571: the fixture carries dates now, because the empty-query default is an ORDERING —
   the three most recently booked businesses — and a fleet with no dates could not tell a correct
   implementation from one that simply takes the first three in render order. */
const FLEET = [
  { business_slug: 'a', business_name: 'Cubbly SPA', industry: 'beauty', bookingEnabled: true,
    appointments: [{ service_name: 'facial', starts_at: '2026-08-20T02:00:00Z' }], requests: [] },
  { business_slug: 'b', business_name: 'QA Kaya Toast', industry: 'cafe', bookingEnabled: true,
    appointments: [], requests: [{ service_name: 'kopi tasting', preferred_at: '2026-08-26T02:00:00Z' }] },
  { business_slug: 'c', business_name: 'Iron Gym', industry: 'fitness', bookingEnabled: false,
    appointments: [], requests: [] },
];
/* A fourth business, booked longest ago, so the cap of three actually excludes somebody. */
const FLEET_OF_FOUR = [
  ...FLEET,
  { business_slug: 'd', business_name: 'Old Barber', industry: 'beauty', bookingEnabled: true,
    appointments: [{ service_name: 'cut', starts_at: '2026-01-02T02:00:00Z' }], requests: [] },
];

test('v549 a sector word finds the businesses in that sector, not just a matching name', () => {
  /* None of these four words appears in any business NAME. They reach the right chips through the
     sector the business declared and the one classifier the category headings already use. */
  assert.deepEqual(runSearch(FLEET, 'salon').shown, ['cubbly spa']);
  assert.deepEqual(runSearch(FLEET, 'hair').shown, ['cubbly spa']);
  assert.deepEqual(runSearch(FLEET, 'gym').shown, ['iron gym']);
  assert.deepEqual(runSearch(FLEET, 'coffee').shown, ['qa kaya toast']);
});

test('v549 a service this customer actually booked is searchable', () => {
  /* "facial" is not the name, not the sector key, and not the category label — it is on the
     appointment. This is the case the owner's own example turns on. */
  assert.ok(runSearch(FLEET, 'facial').shown.includes('cubbly spa'));
  assert.ok(runSearch(FLEET, 'kopi').shown.includes('qa kaya toast'));
});

test('v549 the name still works, and a meaningless query still matches nothing', () => {
  assert.deepEqual(runSearch(FLEET, 'kaya').shown, ['qa kaya toast']);
  assert.deepEqual(runSearch(FLEET, 'zzzz').shown, []);
  /* 'Other' is the classifier's I-don't-know answer AND the bucket every unlabelled business
     falls into, so honouring it would make a junk query match everything unlabelled. */
  const unlabelled = [{ business_slug: 'd', business_name: 'Something', industry: '', bookingEnabled: true }];
  assert.deepEqual(runSearch(unlabelled, 'zzzz').shown, []);
});

/* nestly_v571 (owner, Bookings photo: the helper sentence struck out, and an arrow at the chips —
   "show recent 3 last booked businesses only"). v549's empty state showed no chips and explained
   itself in prose; with the prose gone the default has to carry its own meaning, so it is now the
   three businesses this customer booked with most recently. Typing still searches all of them. */
test('v571 an empty query shows the three most recently booked businesses', () => {
  const { shown, status } = runSearch(FLEET_OF_FOUR, '');
  /* WHICH three, not in what order: the chips stay grouped by sector, which is the chooser's own
     ordering and not something recency should fight. Iron Gym has never been booked, so it is the
     one the cap drops even though it renders before Old Barber. */
  assert.deepEqual([...shown].sort(), ['cubbly spa', 'old barber', 'qa kaya toast']);
  assert.ok(!shown.includes('iron gym'), 'the business with no booking at all is not one of the three');
  assert.equal(status.textContent, '', 'the struck-out prompt is gone');
  assert.equal(status.hidden, true, 'and its line does not hold empty space');
});

test('v571 typing still searches every business, not just the recent three', () => {
  assert.deepEqual(runSearch(FLEET_OF_FOUR, 'iron').shown, ['iron gym'],
    'a business outside the recent three is still reachable by name');
});
