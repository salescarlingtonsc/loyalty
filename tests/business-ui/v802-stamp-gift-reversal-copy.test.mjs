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
import { workspaceTemplateRuntime } from '../support/workspace-template-runtime.mjs';

const app = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

const block = (start, end) => {
  const i = app.indexOf(start);
  assert.ok(i >= 0, `missing block: ${start}`);
  const j = app.indexOf(end, i);
  assert.ok(j > i, `missing end marker for ${start}`);
  return app.slice(i, j + end.length);
};

/* nestly_v952: the points arm's amounts are a reviewed template now, so the slice ends at the
   function's own closing brace rather than at a sentence that has moved into the copy table. */
const resultSrc = block('function reversalResultHtml(kind,result){', "</div>`;\n}");

/* The dialog is ~90 lines of DOM wiring; only its note is under test, so the note expression is
   lifted on its own and evaluated with the same inputs the dialog gives it. */
/* nestly_v953: the note's two arms are reviewed templates now, so the slice ends where the
   expression does rather than on a sentence that has moved into the copy table. */
const noteSrc = block("  const loyaltyNote=kind!=='redemption'?''",
  "credit_cents||0))})}</div>`;");

const money = (cents) => `$${(Number(cents || 0) / 100).toFixed(2)}`;
const esc = (s) => String(s);
const BRAND = { productName: 'Peekaa' };

/* The real template runtime, not a stub: a stub would render every key as its own name and the
   "points restored" assertions below would pass over a broken table. */
const tpl = workspaceTemplateRuntime('en');
const reversalResultHtml = new Function('money', 'BRAND', 'esc', 'workspaceTemplateHtmlV97',
  `${resultSrc}; return reversalResultHtml;`)(money, BRAND, esc, tpl.workspaceTemplateHtmlV97);
const loyaltyNoteFor = new Function('money', 'BRAND', 'esc', 'workspaceTemplateHtmlV97',
  `return function(kind,item){${noteSrc}; return loyaltyNote;};`)(money, BRAND, esc, tpl.workspaceTemplateHtmlV97);

test('a stamp-gift reversal is reported as the gift coming back, not as 0 points', () => {
  const html = reversalResultHtml('redemption', {
    redemption_id: 'r1', restored_points: 0, restored_stamp_claims: 1,
    reopened_stamp_cards: 1, reversed_credit_cents: 0, replayed: false
  });
  assert.match(html, /Gift un-redeemed/);
  /* nestly_v953: each clause of this receipt is its own reviewed key now — the singular and the
     plural of the gift count, the reopened card, the credit, the replay — so the count is read by
     name and the key itself proves the singular was chosen. */
  assert.match(html, /data-workspace-template="stampGiftGivenBack"[^]*?data-workspace-value="claims"[^>]*>1</);
  assert.match(html, /data-workspace-template="stampCardOpenAgain"/);
  assert.doesNotMatch(html, /points restored/,
    'a stamp gift restores no points; saying so describes nothing that happened');
  assert.doesNotMatch(html, /credit compensated/,
    'a gift that carried no credit must not claim a $0.00 compensation');
});

test('a stamp gift that did carry credit still reports the credit', () => {
  const html = reversalResultHtml('redemption', {
    restored_stamp_claims: 1, reopened_stamp_cards: 0, reversed_credit_cents: 500, replayed: true
  });
  assert.match(html, /data-workspace-template="creditCompensatedAmount"[^]*?data-workspace-value="credit"[^>]*>\$5\.00</);
  assert.match(html, /data-workspace-template="exactReplayVerified"/);
  assert.doesNotMatch(html, /stampCardOpenAgain/,
    'a mid-card gift closes no card, so nothing was reopened');
});

test('the POINTS arm is untouched — the stamp branch cannot swallow it', () => {
  const html = reversalResultHtml('redemption', {
    restored_points: 50, reversed_credit_cents: 250, replayed: false
  });
  assert.match(html, /Redemption reversed/);
  /* nestly_v952: both figures ride in named value spans now — read them by name, which also
     catches a render that swapped the points for the credit. */
  assert.match(html, /data-workspace-value="points"[^>]*>50</);
  assert.match(html, /data-workspace-value="credit"[^>]*>\$2\.50</);
  assert.doesNotMatch(html, /stamp/i);
});

test('a sale reversal is untouched', () => {
  const html = reversalResultHtml('sale', { reversed_cents: 1000, refunded_payment_cents: 1000 });
  assert.match(html, /Reversal completed/);
  assert.doesNotMatch(html, /stamp/i);
});

test('the dialog note describes the claim for a stamp gift and the ledger for a points one', () => {
  const stamp = loyaltyNoteFor('redemption', { points_spent: 0, credit_cents: 0 });
  assert.match(stamp, /original claim on the customer&#39;s card/);
  assert.match(stamp, /slot on the card comes back/);
  assert.doesNotMatch(stamp, /FEFO/,
    'a stamp gift has no batch drains; promising that check is a promise about work nobody does');

  const points = loyaltyNoteFor('redemption', { points_spent: 50, credit_cents: 500 });
  assert.match(points, /original points entry/);
  assert.match(points, /FEFO batch drain/);
  assert.match(points, /data-workspace-value="amount"[^>]*>\$5\.00</);

  assert.equal(loyaltyNoteFor('sale', { points_spent: 0, credit_cents: 0 }), '',
    'a sale reversal never showed this note and still must not');
});
