/* nestly_v802 (F059) — the staff Reverse dialog stops describing a stamp gift as points.
 *
 * The server half is proved against production by db/tests/v802_stamp_gift_reversal_and_pin.sql:
 * a stamp gift can now be un-redeemed, and the reversal returns restored_points 0 with
 * restored_stamp_claims / reopened_stamp_cards instead. The client half is here, because the two
 * strings the cashier actually reads were both written for the points arm only:
 *
 *   reversalResultHtml said "0 points restored · $0.00 credit compensated" — a true sentence that
 *   describes nothing that happened, over a free coffee that was just given back.
 *   the dialog's standing note promised a check of "the original points entry, every FEFO batch
 *   drain" — machinery a stamp gift has none of.
 *
 * These EXECUTE the shipped functions, lifted verbatim out of app/app.js and run against stubs,
 * rather than grepping for the new wording: a grep stays green while the branch is dead.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

const block = (start, end) => {
  const i = app.indexOf(start);
  assert.ok(i >= 0, `missing block: ${start}`);
  const j = app.indexOf(end, i);
  assert.ok(j > i, `missing end marker for ${start}`);
  return app.slice(i, j + end.length);
};

const resultSrc = block('function reversalResultHtml(kind,result){',
  "${result.replayed?' · exact replay verified':''}.</div>`;\n}");

/* The dialog is ~90 lines of DOM wiring; only its note is under test, so the note expression is
   lifted on its own and evaluated with the same inputs the dialog gives it. */
const noteSrc = block("  const loyaltyNote=kind!=='redemption'?''",
  'nothing in the history is deleted.</div>`;');

const money = (cents) => `$${(Number(cents || 0) / 100).toFixed(2)}`;
const esc = (s) => String(s);
const BRAND = { productName: 'Peekaa' };

const reversalResultHtml = new Function('money', 'BRAND', 'esc',
  `${resultSrc}; return reversalResultHtml;`)(money, BRAND, esc);
const loyaltyNoteFor = new Function('money', 'BRAND', 'esc',
  `return function(kind,item){${noteSrc}; return loyaltyNote;};`)(money, BRAND, esc);

test('a stamp-gift reversal is reported as the gift coming back, not as 0 points', () => {
  const html = reversalResultHtml('redemption', {
    redemption_id: 'r1', restored_points: 0, restored_stamp_claims: 1,
    reopened_stamp_cards: 1, reversed_credit_cents: 0, replayed: false
  });
  assert.match(html, /Gift un-redeemed/);
  assert.match(html, /1 stamp gift given back/);
  assert.match(html, /stamp card is open again/);
  assert.doesNotMatch(html, /points restored/,
    'a stamp gift restores no points; saying so describes nothing that happened');
  assert.doesNotMatch(html, /credit compensated/,
    'a gift that carried no credit must not claim a $0.00 compensation');
});

test('a stamp gift that did carry credit still reports the credit', () => {
  const html = reversalResultHtml('redemption', {
    restored_stamp_claims: 1, reopened_stamp_cards: 0, reversed_credit_cents: 500, replayed: true
  });
  assert.match(html, /\$5\.00 credit compensated/);
  assert.match(html, /exact replay verified/);
  assert.doesNotMatch(html, /stamp card is open again/,
    'a mid-card gift closes no card, so nothing was reopened');
});

test('the POINTS arm is untouched — the stamp branch cannot swallow it', () => {
  const html = reversalResultHtml('redemption', {
    restored_points: 50, reversed_credit_cents: 250, replayed: false
  });
  assert.match(html, /Redemption reversed/);
  assert.match(html, /50 points restored/);
  assert.match(html, /\$2\.50 credit compensated/);
  assert.doesNotMatch(html, /stamp/i);
});

test('a sale reversal is untouched', () => {
  const html = reversalResultHtml('sale', { reversed_cents: 1000, refunded_payment_cents: 1000 });
  assert.match(html, /Reversal completed/);
  assert.doesNotMatch(html, /stamp/i);
});

test('the dialog note describes the claim for a stamp gift and the ledger for a points one', () => {
  const stamp = loyaltyNoteFor('redemption', { points_spent: 0, credit_cents: 0 });
  assert.match(stamp, /original claim on the customer's card/);
  assert.match(stamp, /slot on the card comes back/);
  assert.doesNotMatch(stamp, /FEFO/,
    'a stamp gift has no batch drains; promising that check is a promise about work nobody does');

  const points = loyaltyNoteFor('redemption', { points_spent: 50, credit_cents: 500 });
  assert.match(points, /original points entry/);
  assert.match(points, /FEFO batch drain/);
  assert.match(points, /\$5\.00 reward credit/);

  assert.equal(loyaltyNoteFor('sale', { points_spent: 0, credit_cents: 0 }), '',
    'a sale reversal never showed this note and still must not');
});
