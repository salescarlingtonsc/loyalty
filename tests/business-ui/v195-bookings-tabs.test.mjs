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
  assert.match(src, /dataset\.bookingsTabsV195==='1'/, 'must be idempotent across re-renders');
});

test('the portal link stays visible in both tabs', () => {
  const i = app.indexOf('function enhanceBookingsTabsV195');
  const src = app.slice(i, i + 2600);
  assert.match(src, /portalCard=root\.querySelector\('#cp'\)/);
  assert.match(src, /if\(child===portalCard\|\|child\.contains\(tabs\)\)return/);
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
  assert.match(src, /publicAppUrl\(`b\/\$\{encodeURIComponent\(S\.biz\.slug\)\}`\)/);
  assert.ok(!/receipt\/\$\{.*saleId/.test(src), 'must not mint a per-receipt public URL');
});

test('a walk-in gets no QR, and a CDN failure still leaves a usable receipt', () => {
  assert.match(app, /\$\{d\.walkin\?''\:`<div class="receipt-qr-block"/);
  const i = app.indexOf("const receiptQrHost=");
  const src = app.slice(i, i + 900);
  assert.match(src, /\.catch\(\(\)=>\{/);
  assert.match(src, /word-break:break-all/, 'the link must be printable as text when the QR library fails');
});
