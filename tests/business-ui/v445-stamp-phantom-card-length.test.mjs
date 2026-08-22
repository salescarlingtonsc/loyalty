/* nestly_v445 — REG-001: the stamp editor drew a card length nobody had set.
 *
 * Confirmed live and against production SQL on qa-kaya-toast (business
 * 38b30e6d-de73-4c2b-a2ca-19b08950896c): loyalty_programs.stamp_target = 15, and the current
 * loyalty_program_versions row agrees at 15, while the gifts sit at stamps 4, 6, 15, 80 and 1000.
 * The editor at #/grow/points drew ONE HUNDRED slots and put 100 in the "Card length in stamps"
 * field, on every fresh render. The pre-fix expression was
 *
 *     const growStampsCardLenV416 = Math.min(GROW_STAMPS_MAX_LEN_V416,
 *       Math.max(1, growStampsTargetV416 || GROW_STAMPS_DEFAULT_LEN_V416, growStampsHighestGiftV416));
 *
 * — the drawn length was stretched to cover the highest gift and then clamped to 100. That number
 * is not merely cosmetic: every length control on the screen is built from it (the − stepper emits
 * len-1, the + stepper and the grid's trailing "+" emit len+1, and the typed field's commit guard
 * compares against it), so one tap would have written the phantom length to loyalty_programs
 * through business_set_stamp_card_length_v414.
 *
 * This file EXECUTES the shipped render block and the shipped length-write handlers — no source
 * regexes standing in for behaviour. The harness is validated by a negative control at the bottom
 * which runs the identical assertions against origin/main's app.js and requires them to FAIL.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const esc = v => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const CUI = { icon: name => `<svg data-icon="${name}"></svg>` };

/* ---------------------------------------------------------------- the render, as it ships ---- */

const slice = (source, start, end) => {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing region ${start} … ${end}`);
  return source.slice(from, to + end.length);
};

/* The whole v416/v422/v445 stamp-editor block, from the first constant to the end of the stranded
   note, evaluated verbatim. Its inputs — the saved card length and the gifts — are injected,
   because they are the entire question. */
/* nestly_v453: the stamp editor now renders two of its strings through the workspace copy
   machinery (the disabled length steppers explain their refusal, and that sentence is reviewed,
   localised copy). The REAL machinery is extracted with the block under test rather than stubbed —
   a stub would happily return text for a key nobody registered, which is the one thing the
   workspace audit exists to prevent. */
const workspaceRigV453 = source => {
  const from = source.indexOf('const WORKSPACE_TEMPLATE_COPY_V97=Object.freeze({');
  const to = source.indexOf('const workspaceTemplateInnerHtmlV97=', from);
  assert.ok(from >= 0 && to > from, 'workspace template machinery not found in this revision');
  return source.slice(from, to);
};
const renderBlock = source =>
  `${workspaceRigV453(source)}\n`
  + slice(source, '  const GROW_STAMPS_DEFAULT_LEN_V416=15;', "</div>`:'';");

const render = ({ stampTarget = 0, gifts = [], canSetupGrow = true, busy = false,
                  snapshot } = {}) => {
  const snap = snapshot || { loyalty: { stamp_target: stampTarget } };
  return new Function(
    'snapshot', 'growStampsLevelsSortedV350', 'growStampsRewardAtV410', 'canSetupGrow',
    'growPointsBusyV326', 'CUI', 'esc', 'workspaceLocale', `
    ${renderBlock(appJs)}
    return {growStampsCardLenV416, growStampsTargetV416, growStampsHighestGiftV416,
      growStampsStrandedV416, growStampsCardLengthBarV416, growStampsGridV416,
      growStampsStrandedNoteV416};`)(
    snap,
    gifts.slice().sort((a, b) => Number(a.cost_points || 0) - Number(b.cost_points || 0)),
    new Map(gifts.map(g => [Math.max(0, Number(g.cost_points) || 0), g]).filter(([n]) => n > 0)),
    canSetupGrow, busy, CUI, esc, 'en');
};

const GIFT = (name, stamps) => ({ id: `r-${stamps}`, customer_name: name, cost_points: stamps });
/* qa-kaya-toast as production holds it today: a 15-stamp card, two gifts past its end. */
const KAYA = [GIFT('Kaya Butter Supreme', 4), GIFT('Free Kopi Set', 6),
  GIFT('Triple-Shot Gula Melaka Kaya', 15), GIFT('Free Kopi', 80),
  GIFT('Free Facial Cream Ultra Hydrating', 1000)];

const cells = markup =>
  [...markup.matchAll(/data-grow-stamps-cell-v416="(\d+)"/g)].map(m => Number(m[1]));
const lenWrites = markup =>
  [...markup.matchAll(/data-grow-stamps-len-v416="(-?\d+)"/g)].map(m => Number(m[1]));
const fieldValue = markup => {
  const m = /data-grow-stamps-lenfield-v422/.test(markup)
    && /<input[^>]*data-grow-stamps-lenfield-v422[^>]*>/.exec(markup);
  assert.ok(m, 'the length field is not in this markup');
  return Number(/value="(\d+)"/.exec(m[0])[1]);
};

/* ------------------------------------------------------------------------- the assertions ---- */

const assertHonestLength = source => {
  /* Written against a source string so the negative control can run the identical body. */
  const build = (opts) => {
    const snap = { loyalty: { stamp_target: opts.stampTarget } };
    return new Function(
      'snapshot', 'growStampsLevelsSortedV350', 'growStampsRewardAtV410', 'canSetupGrow',
      'growPointsBusyV326', 'CUI', 'esc', 'workspaceLocale', `
      ${`${workspaceRigV453(source)}\n`
        + slice(source, '  const GROW_STAMPS_DEFAULT_LEN_V416=15;', "</div>`:'';")}
      return {growStampsCardLenV416, growStampsCardLengthBarV416, growStampsGridV416,
        growStampsStrandedNoteV416};`)(
      snap, opts.gifts.slice().sort((a, b) => a.cost_points - b.cost_points),
      new Map(opts.gifts.map(g => [g.cost_points, g])), true, false, CUI, esc, 'en');
  };
  const g = build({ stampTarget: 15, gifts: KAYA });
  assert.equal(g.growStampsCardLenV416, 15);
  assert.deepEqual(cells(g.growStampsGridV416),
    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
  assert.equal(fieldValue(g.growStampsCardLengthBarV416), 15);
  assert.deepEqual(lenWrites(g.growStampsCardLengthBarV416).sort((a, b) => a - b), [14, 16]);
};

test('v445 a 15-stamp card with a gift at 1000 draws 15 slots and reads 15', () => {
  assertHonestLength(appJs);
  const g = render({ stampTarget: 15, gifts: KAYA });
  assert.equal(g.growStampsTargetV416, 15, 'server truth, unchanged');
  assert.equal(g.growStampsHighestGiftV416, 1000, 'the out-of-range gift is still seen…');
  assert.equal(g.growStampsCardLenV416, 15, '…but it is not what the card is drawn from');
  /* The grid's own trailing "+" is a length write too, and it must offer 16, not 101. */
  assert.deepEqual(lenWrites(g.growStampsGridV416), [16]);
});

test('v445 the out-of-range gifts get a warning, are named, and are not grid slots', () => {
  const g = render({ stampTarget: 15, gifts: KAYA });
  assert.equal(g.growStampsStrandedV416, true);
  /* v363's warning survives, word for word in its heading. */
  assert.match(g.growStampsStrandedNoteV416, /Stamps past 15 cannot be claimed yet/);
  assert.match(g.growStampsStrandedNoteV416, /2 gifts sit past the end of it/,
    'both stranded gifts are counted — the old copy named only the highest');
  assert.doesNotMatch(g.growStampsGridV416, /is-past-v416/,
    'nothing beyond stamp 15 is drawn as a slot of this card');
  const chips = g.growStampsStrandedNoteV416.slice(
    g.growStampsStrandedNoteV416.indexOf('grow-stamps-strandedgifts-v445'));
  const chipped = [...chips.matchAll(/data-grow-points-gift-edit-v343="([^"]+)"/g)].map(m => m[1]);
  assert.deepEqual(chipped, ['r-80', 'r-1000'],
    'each stranded gift is a chip that opens its own gift form, so the owner can move it');
  assert.match(chips, /is-past-v416/, 'drawn in the warning style, in the warning band');
  /* And nothing here deletes or rewrites the owner's gift — it is still listed. */
  assert.match(chips, /Free Facial Cream Ultra Hydrating/);
});

test('v445 the one-tap "make the card N stamps" fix is withheld when N exceeds the server bound', () => {
  /* business_set_stamp_card_length_v414 caps at 100. Offering "Make the card 1000 stamps" is
     offering a button that can only fail. */
  const far = render({ stampTarget: 15, gifts: KAYA });
  assert.deepEqual(lenWrites(far.growStampsStrandedNoteV416), [],
    'no length button at all when the only reachable fix is out of the server\'s range');
  const near = render({ stampTarget: 15, gifts: [GIFT('Free Lotion', 20)] });
  assert.deepEqual(lenWrites(near.growStampsStrandedNoteV416), [20],
    'but a gift at stamp 20 is still one tap away from being reachable');
});

test('v445 the − stepper is not disabled by a gift that is off the card', () => {
  /* Pre-fix, the guard was growStampsCardLenV416 <= max(1, highestGift): with a gift at 1000 the
     owner could not shorten the card at all, on the very screen they had to go to to fix it. */
  const g = render({ stampTarget: 15, gifts: [GIFT('Kaya Butter Supreme', 4),
    GIFT('Free Kopi Set', 6), GIFT('Free Facial Cream Ultra Hydrating', 1000)] });
  const minus = /<button[^>]*data-grow-stamps-len-v416="14"[^>]*>/.exec(g.growStampsCardLengthBarV416)[0];
  assert.doesNotMatch(minus, /disabled/,
    'the highest gift ON the card is at stamp 6, so 14 is perfectly safe');
  /* A gift that IS on the card still blocks shortening past it — that rule is untouched. */
  const onCard = render({ stampTarget: 10, gifts: [GIFT('Free Lotion', 10)] });
  assert.match(/<button[^>]*data-grow-stamps-len-v416="9"[^>]*>/
    .exec(onCard.growStampsCardLengthBarV416)[0], /disabled/);
  /* qa-kaya-toast's own shape: a gift sits on the last stamp, so − is still refused there — for
     the right reason this time, not because of the gift at 1000. */
  assert.match(/<button[^>]*data-grow-stamps-len-v416="14"[^>]*>/
    .exec(render({ stampTarget: 15, gifts: KAYA }).growStampsCardLengthBarV416)[0], /disabled/);
});

test('v445 rendering twice does not drift, and does not mutate the snapshot', () => {
  /* The live defect re-derived the phantom length on EVERY render, so a second render had to be
     checked as well as the first — and the render must never write back to snapshot.loyalty. */
  const snapshot = { loyalty: { stamp_target: 15 } };
  const first = render({ gifts: KAYA, snapshot });
  const second = render({ gifts: KAYA, snapshot });
  const third = render({ gifts: KAYA, snapshot });
  assert.deepEqual(
    [first.growStampsCardLenV416, second.growStampsCardLenV416, third.growStampsCardLenV416],
    [15, 15, 15]);
  assert.deepEqual([fieldValue(first.growStampsCardLengthBarV416),
    fieldValue(second.growStampsCardLengthBarV416),
    fieldValue(third.growStampsCardLengthBarV416)], [15, 15, 15]);
  assert.equal(snapshot.loyalty.stamp_target, 15, 'the render is a reader, not a writer');
});

/* ------------------------------------------------ the WRITE path, executed at the sb boundary - */

/* Everything from the publish toast down to the end of the typed field's wiring, run verbatim.
   The only stubs are OUTSIDE the code under test: sb (a recording thenable), the toast, the
   re-render, and the DOM the handlers query. */
const wiringSrc = () => {
  const start = appJs.indexOf('  const growStampPublishToastV433=(res,fallback)=>{');
  const end = appJs.indexOf('  const growPointsAddCancel=', start);
  assert.ok(start >= 0 && end > start, 'missing the length-write wiring');
  return appJs.slice(start, end);
};

/* A DOM shim carrying only what these handlers touch: querySelectorAll over the length controls
   found in the real rendered markup, and one input element for the typed field. */
const domFor = markup => {
  const buttons = lenWrites(markup).map(value => ({
    dataset: { growStampsLenV416: String(value) }, onclick: null,
  }));
  const field = /data-grow-stamps-lenfield-v422/.test(markup)
    ? { value: String(fieldValue(markup)), onblur: null, onkeydown: null } : null;
  return {
    buttons, field,
    querySelectorAll(sel) {
      if (sel === '[data-grow-stamps-len-v416]') return buttons;
      throw new Error(`unexpected querySelectorAll(${sel})`);
    },
    querySelector(sel) {
      if (sel === '[data-grow-stamps-lenfield-v422]') return field;
      throw new Error(`unexpected querySelector(${sel})`);
    },
  };
};

const wireUp = ({ stampTarget = 15, gifts = KAYA } = {}) => {
  const g = render({ stampTarget, gifts });
  const markup = g.growStampsCardLengthBarV416 + g.growStampsGridV416 + g.growStampsStrandedNoteV416;
  const outerMain = domFor(markup);
  const calls = [];
  /* Supabase builders are lazy thenables — a stub that is not awaitable would let a missing
     await pass unnoticed, so this one records and resolves. */
  const sb = {
    rpc(name, payload) {
      calls.push({ name, payload });
      return { then: resolve => resolve({ data: { publish_status: 'published' }, error: null }) };
    },
  };
  const snapshot = { loyalty: { stamp_target: stampTarget } };
  new Function('outerMain', 'sb', 'snapshot', 'S', 'toast', 'growRerenderV322', 'isGrowCurrent',
    'ownerErrorText', 'workspaceTemplateTextV97', 'growStampsCardLenV416',
    'GROW_STAMPS_MAX_LEN_V416', `
    let growPointsBusyV326=false, growPointsErrorV326='';
    ${wiringSrc()}
    return {growStampsSetLengthV422};`)(
    outerMain, sb, snapshot, { biz: { id: 'biz-1' } }, () => {}, () => {}, () => true,
    e => String(e), () => 'saved', g.growStampsCardLenV416, 100);
  return { g, outerMain, calls, snapshot };
};

test('v445 the steppers write the length the owner stepped to, never the derived one', async () => {
  const { outerMain, calls } = wireUp();
  /* Buttons, in the order the real markup produced them: −(14), +(16) from the bar, +(16) from
     the grid. The stranded note contributes none here, its fix button being withheld at 1000. */
  assert.deepEqual(outerMain.buttons.map(b => Number(b.dataset.growStampsLenV416)), [14, 16, 16]);
  for (const button of outerMain.buttons) await button.onclick();
  assert.deepEqual(calls.map(c => c.name),
    ['business_set_stamp_card_length_v414', 'business_set_stamp_card_length_v414',
      'business_set_stamp_card_length_v414']);
  assert.deepEqual(calls.map(c => c.payload.p_stamps), [14, 16, 16],
    'a 15-stamp card steps to 14 and 16 — not to 99 and 101 off a phantom 100');
});

test('v445 the typed field commits what was typed, and stays silent when unchanged', async () => {
  const { outerMain, calls } = wireUp();
  assert.equal(outerMain.field.value, '15', 'pre-filled from the card, not from the gift at 1000');
  /* Unchanged: no request. Pre-fix the field read 100, so simply tabbing out of it after typing
     the card's real length (15) would have been a CHANGE, and would have sent 15 — or worse, a
     stray step would have sent 99/101. */
  outerMain.field.onblur();
  assert.deepEqual(calls, []);
  outerMain.field.value = '20';
  outerMain.field.onblur();
  assert.deepEqual(calls.map(c => c.payload.p_stamps), [20]);
  /* Out of the server's range: restored, not sent. */
  outerMain.field.value = '400';
  outerMain.field.onblur();
  assert.equal(calls.length, 1);
  assert.equal(outerMain.field.value, '15');
});

test('v445 the gift form is the ONLY other writer on this screen, and it sends no length', () => {
  /* Audit of every write path out of #/grow/points: the two steppers and the typed field (above,
     all three routed through the single business_set_stamp_card_length_v414 call site) and the
     gift save. The gift save must not carry a length — deriving one there would reintroduce the
     defect through the back door. */
  const save = slice(appJs, "  const growPointsAddSave=outerMain.querySelector('[data-grow-points-add-save-v326]');",
    '  /* V356: the old \'prompt\' state');
  assert.match(save, /sb\.rpc\('business_create_reward_v326'/);
  assert.match(save, /sb\.rpc\('business_update_reward_v326'/);
  assert.doesNotMatch(save, /p_stamps|stamp_target|growStampsCardLenV416/,
    'saving a gift never sets the card length');
  assert.equal((appJs.match(/sb\.rpc\('business_set_stamp_card_length_v414'/g) || []).length, 1,
    'still exactly one length call site');
});

test('v445 the stranded-gift chips have a rule to lay them out', () => {
  /* The chips reuse .grow-stamps-editcell-v416, which is position-absolute-anchored for its gift
     icon and sized 44px; without its own flex container it would inherit the warning band's block
     flow and the icons would clip into the paragraph above. */
  const html = readFileSync(join(root, 'app', 'index.html'), 'utf8');
  const rule = /\.grow-stamps-strandedgifts-v445\{([^}]*)\}/.exec(html);
  assert.ok(rule, 'the chip row must be laid out, not left to inherit');
  assert.match(rule[1], /display:flex/);
  assert.match(rule[1], /flex-wrap:wrap/);
  assert.match(rule[1], /margin-top:2\dpx/, 'clearance for the icon that hangs 15px above a chip');
  assert.match(html, /\.grow-stamps-editcell-v416\.is-past-v416\{[^}]*var\(--warn\)/,
    'and the warning style the chips wear is still defined');
});

/* ------------------------------------------------------------------ negative control ---------- */

test('v445 NEGATIVE CONTROL: these assertions fail against the pre-fix source', () => {
  const before = execFileSync('git', ['show', 'origin/main:app/app.js'],
    { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  assert.match(before,
    /Math\.max\(1,growStampsTargetV416\|\|GROW_STAMPS_DEFAULT_LEN_V416,growStampsHighestGiftV416\)/,
    'origin/main must still carry the derivation this fix removed; if it does not, re-point this');
  assert.throws(() => assertHonestLength(before),
    /Expected values to be strictly equal|Expected inputs to be strictly deep-equal/,
    'the harness must be able to see the bug, or it proves nothing about the fix');
  /* And name what it saw, so the control is not merely "something threw". */
  let phantom = null;
  try { assertHonestLength(before); } catch (e) { phantom = e.actual; }
  assert.equal(phantom, 100, 'the pre-fix editor drew a hundred slots for a fifteen-stamp card');
});
