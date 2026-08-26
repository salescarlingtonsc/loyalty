import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

/* nestly_v540 — the Customer 360 summary card fills its column, like the card beneath it.
 *
 * Owner, photo 1: a red box drawn over the empty space to the right of the summary card,
 * "enlarge the boxes to make the boxes look aligned with its counterparts below".
 *
 * AN AXIS FLIP, invisible in either change on its own. V294/V295 wrote `align-self:start` when
 * .c360-content-split-v295 was a GRID and these were grid cells — there align-self is the BLOCK
 * axis, so it meant "do not stretch to the tallest card's height". nestly_v476 then made each
 * column `display:flex;flex-direction:column`, where the cross axis is HORIZONTAL, and the same
 * declaration began shrinking the cards to their content width.
 *
 * MEASURED in Chrome against the Referral & consent card directly beneath, which has no
 * align-self and stretches normally:
 *   before  summary 230px  vs referral 480 / 688 / 928 at 1024 / 1440 / 1920
 *   after   summary 480 / 688 / 928 — identical at every width; mobile was already 342/342
 */

const css = readFileSync(new URL('../../app/app.css', import.meta.url), 'utf8');
const rule = (selector) => css.match(new RegExp(`\\${selector}\\{[^}]*\\}`))?.[0] ?? '';

test('V540 the summary card does not pin itself to its content width', () => {
  const summary = rule('.c360-summary-card-v294');
  assert.ok(summary, 'the rule still exists');
  assert.ok(!/align-self:\s*(start|flex-start)/.test(summary),
    'inside a column flex container align-self:start is the HORIZONTAL axis — it froze this card '
    + 'at 230px while the card below it filled the column');
});

test('V540 nor does the stack that holds it when a package card is present', () => {
  const stack = rule('.c360-summary-stack-v442');
  assert.ok(stack, 'the rule still exists');
  assert.ok(!/align-self:\s*(start|flex-start)/.test(stack),
    'the same flip applies to the wrapper — a customer with packages would keep the narrow card');
});

test('V540 the column itself KEEPS align-self:start, because there it still means the block axis', () => {
  /* .c360-col-v476 is a child of .split, which is a real grid. Removing it there would stretch a
     short column to the height of the taller one and re-open the gaps v476 closed. */
  const col = rule('.c360-col-v476');
  assert.match(col, /align-self:start/,
    'this one is a grid child and its align-self is correct — do not "tidy" it away with the others');
  assert.match(col, /display:flex/);
  assert.match(col, /flex-direction:column/);
});

test('V540 the mobile stacking rules are untouched', () => {
  assert.match(css, /\.c360-summary-card-v294\{order:-1;width:100%\}/,
    'below 960px the figures still lead, at full width');
  assert.match(css, /\.c360-summary-stack-v442\{order:-1;width:100%\}/);
});
