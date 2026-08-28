import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

/* nestly_v584 — the V195/V288 tab split is DELETED, at the owner's instruction.
   Owner photo 13 struck "Booking settings" through and wrote "delete booking settings"; asked
   what should become of what the tab held (the seating switch, Tables / capacity and the bookings
   CSV import), they chose to delete the tab AND its contents. So the four tests that used to
   stand here — the enhancer, the DOM split, the portal card above the tabs and the tab a11y — are
   replaced by ONE that holds the deletion in place, because a re-grown Booking settings tab is
   exactly the regression this file is now for. What governs how customers book was never in that
   tab: booking rules, opening hours, staff choice and auto-approve moved to Customer Interface ->
   Appointment Setting in V325, and that pointer is still asserted below. */
test('nestly_v584 bookings is the requests list, with no settings tab behind it', () => {
  assert.doesNotMatch(app, /enhanceBookingsTabsV195/);
  assert.doesNotMatch(app, /bookingsTabSettings/);
  assert.doesNotMatch(app, /Booking settings<\/button>/);
  // ...and the contents that lived in it are gone with it.
  assert.doesNotMatch(app, /id="tblAdd"/);
  assert.doesNotMatch(app, /id="bkCsvf"/);
  assert.doesNotMatch(app, /setTakesTablesV223/);
  // The page still marks its own shell, and still points at where the rules actually live.
  assert.match(app, /data-bookings-shell="head"/);
  assert.match(app, /Auto-approve is \$\{S\.biz\.auto_approve_changes\?'on':'off'\}\. Change this in <a href="#\/customer-interface\/appointment">/);
});

test('nestly_v584 a booking decision is a tick and a cross, and the list pages at 20', () => {
  /* Owner photo 13: Confirm and Decline struck out, a green tick and a red cross drawn in.
     Photo 2: the pager drawn under the request list — "every page got 20 lists". */
  assert.match(app, /booking-decision-yes-v584/);
  assert.match(app, /booking-decision-no-v584/);
  assert.doesNotMatch(app, /booking-decision" data-request="\$\{b\.id\}"[^>]*>Confirm</);
  // Both buttons keep a spoken name, so dropping the words costs a screen reader nothing.
  assert.match(app, /confirmBookingFor/);
  assert.match(app, /declineBookingFor/);
  assert.match(app, /pagerHtmlV584\(\{scope:'bookings'/);
  assert.match(app, /const PAGE_SIZE_V584=20;/);
});

test('the receipt QR opens the customer wallet, never a public receipt URL', () => {
  // Owner: "allow for QRcode to let user to download or view". A public per-receipt link would
  // expose items, amounts, staff and a points balance behind only an unguessable string — a PDPA
  // decision, not an implementation detail. The portal shows the same customer the same history
  // once signed in.
  assert.match(app, /id="receiptWalletQr"/);
  const i = app.indexOf("const receiptQrHost=");
  const src = app.slice(i, i + 900);
  /* V388 (owner, photo 2): it encoded `b/<slug>` — the PUBLIC BOOKING PORTAL — while the caption
     printed under it promised "your rewards, points and past visits", so a customer scanning
     their own receipt landed on a form to book another appointment. `wallet/<slug>` is the route
     that shows what the caption says. The PDPA rule this test exists for is untouched and still
     asserted below: no per-receipt public URL is minted, and the wallet shows the signed-in
     customer their OWN history rather than this receipt's contents. */
  assert.match(src, /publicAppUrl\(`wallet\/\$\{encodeURIComponent\(S\.biz\.slug\)\}`\)/);
  assert.doesNotMatch(src, /publicAppUrl\(`b\//, 'the booking portal is not the customer wallet');
  assert.ok(!/receipt\/\$\{.*saleId/.test(src), 'must not mint a per-receipt public URL');
});

test('a walk-in gets no QR, and a CDN failure still leaves a usable receipt', () => {
  assert.match(app, /\$\{d\.walkin\?''\:`<div class="receipt-qr-block"/);
  const i = app.indexOf("const receiptQrHost=");
  /* V388 widened this block (the code is tappable now), so the slice widened with it. */
  const src = app.slice(i, i + 2600);
  assert.match(src, /\.catch\(\(\)=>\{/);
  assert.match(src, /word-break:break-all/, 'the link must be printable as text when the QR library fails');
});
