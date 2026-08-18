import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

test('bookings separates the thing you act on from the things you set once', () => {
  // Owner: "below here got different tab so it's not messy" — the requests table was buried
  // between customer app actions, change requests, tables/capacity and CSV import.
  assert.match(app, /function enhanceBookingsTabsV195/);
  assert.match(app, /id="bookingsTabRequests"/);
  assert.match(app, /id="bookingsTabSettings"/);
  assert.match(app, /enhanceBookingsTabsV195\(M\(\)\)/);
});

test('the split is done in the DOM so every existing id keeps working', () => {
  const i = app.indexOf('function enhanceBookingsTabsV195');
  const src = app.slice(i, i + 2600);
  assert.match(src, /root\.querySelector\('#blist'\)/);
  assert.ok(!src.includes('innerHTML=`<div class="card" id="blist"'),
    'the shared template must not be rewritten; load paths depend on those ids');
  /* V288 (audit A2 HIGH 3): RETARGETED, not deleted. A literal '1' was idempotent across
     re-renders in the WRONG direction — dataset survives an innerHTML reset, so the realtime
     re-render skipped the enhancement entirely and destroyed the tabs it was meant to protect.
     The guard is now a per-render token, which is idempotent WITHIN a render and re-arms
     between them. */
  assert.match(src, /dataset\.bookingsTabsV195!==String\(bookingsShellTokenV288\)/,
    'must be idempotent within a render, and re-arm between renders');
});

test('the portal link stays visible in both tabs', () => {
  const i = app.indexOf('function enhanceBookingsTabsV195');
  const src = app.slice(i, i + 2600);
  /* V288 (audit A2 HIGH 2): RETARGETED, not deleted. #cp lives in the .topbar, so
     closest('.card,section') returned NULL and the portal card was never actually recognised —
     this assertion passed while the behaviour it names was broken. The nodes that stay above
     the tabs are marked with data-bookings-shell now, so the check is on the real mechanism. */
  /* V375: the portal card moved to Appointments (owner, photo 5), so the shell marker that
     stays above the tabs here is the head — the mechanism this test names is unchanged. */
  assert.match(app, /data-appointments-shell="portal"/);
  assert.match(app, /data-bookings-shell="head"/);
  assert.match(src, /if\(child\.hasAttribute\('data-bookings-shell'\)\|\|child\.contains\(tabs\)\)return/);
});

test('tabs are real tabs for assistive technology', () => {
  const i = app.indexOf('function enhanceBookingsTabsV195');
  const src = app.slice(i, i + 2600);
  assert.match(src, /role','tablist'/);
  assert.match(src, /role="tab"/);
  assert.match(src, /role','tabpanel'/);
  assert.match(src, /aria-selected/);
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
