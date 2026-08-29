import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

/* nestly_v532 — Redeem now bottom-left, Book now bottom-right, on EVERY hero page.
 *
 * The owner has asked for this twice. nestly_v517 moved the action row out of the narrow copy
 * column that sits beside the gift photo, which was the right move — but left behind the v491
 * rule that had forced the pair to stack BECAUSE they were in that column. So the swipe pages
 * went on stacking with a whole card's width to spare, and photo 1 came back.
 *
 * Measured in Chrome on the real stylesheet before removing it:
 *   with the rule    390px -> one 326px column, stacked
 *   without the rule 390px -> 158px each, Redeem at x32 and Book at x200, side by side
 * 158px clears the 150px v491 was protecting, which is why removing it is safe rather than a
 * reversal of that decision.
 */

const css = readFileSync(new URL('../../app/app.css', import.meta.url), 'utf8');

test('V532 nothing forces the hero action row into a single column on a card with a photo', () => {
  assert.ok(!css.includes('.customer-hero-has-photo-v468 .customer-business-summary-actions-v349{grid-template-columns:1fr'),
    'the v491 stacking rule is what put Redeem now above Book now; its premise (the buttons living '
    + 'in the 222px copy column) was removed by v517 and the rule must go with it');
});

test('V532 the action row is two columns by default', () => {
  assert.match(css, /\.customer-business-summary-actions-v349\{[^}]*grid-template-columns:1fr 1fr!important/,
    'side by side is the base layout — Redeem now left, Book now right');
});

test('V532 a lone button still spans the row', () => {
  assert.match(css, /\.customer-business-summary-actions-v349:has\(>:only-child\)\{grid-template-columns:1fr!important\}/,
    'a reward with no booking link must not leave half the row empty');
});

/* nestly_v613 (owner photo 3, Claim reward and Book now ringed together as one row — "i want this
   format" — with the full-width Book now bar beneath them struck out). The phone the owner
   photographed is narrower than 380px, and this media query was the only thing still stacking the
   pair there, so the one screen the ruling was about was the one screen it did not reach. The rule
   is gone. The width it was protecting is fine without it: at 375px the card's 335px of inner
   width less the 10px gap gives each button 162px — wider than the 158px v532 itself measured and
   accepted at 390px, and above the 150px v491 was guarding. */
test('V613 the pair stays side by side at every width', () => {
  assert.ok(!css.includes('.customer-business-summary-actions-v349{grid-template-columns:1fr!important}'),
    'no media query may stack the hero actions any more');
  assert.match(css, /\.customer-business-summary-actions-v349\{[^}]*grid-template-columns:1fr 1fr!important/,
    'the two-column rule is what governs the row at every width');
});

