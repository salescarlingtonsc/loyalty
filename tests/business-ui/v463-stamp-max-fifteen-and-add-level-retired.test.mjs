/* nestly_v463 — owner rulings R3(a) and R3(b), 2026-08-23.
 *
 * R3(a) the business editor's maximum card length is 15 stamps: the input's max, both steppers,
 *       the grid's trailing "+", the v445 one-tap stranded fix, the typed field's commit guard
 *       and the server's own write guard in business_set_stamp_card_length_v414. EXISTING
 *       stamp_target values are NOT mutated, so a card already stored longer than 15 must be
 *       DRAWN at its real length while every control refuses to make it longer.
 * R3(b) "+ Add level" is retired from #/grow/points. Slot-tap and the v445 stranded-gift chips
 *       are the only placement paths, and the gift form refuses a stamp above the maximum.
 *
 * Everything here EXECUTES the shipped render block and the shipped save handler — the same
 * extraction rig tests/business-ui/v445-stamp-phantom-card-length.test.mjs established, with the
 * real workspace copy machinery rather than a stub, so an unregistered sentence renders empty and
 * fails instead of quietly passing. The negative control at the bottom runs the identical
 * assertions against origin/main and requires them to FAIL.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const BASE = 'b290151';   /* origin/main at the head of this wave */

const esc = v => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const CUI = { icon: name => `<svg data-icon="${name}"></svg>` };
const gitShow = ref => execFileSync('git', ['show', ref], { cwd: root, encoding: 'utf8',
  maxBuffer: 64 * 1024 * 1024 });

const slice = (source, start, end) => {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing region ${start} … ${end}`);
  return source.slice(from, to + end.length);
};
/* Same, but STOPPING before the end marker — for regions that are executed rather than matched,
   where a trailing half-statement is a SyntaxError. */
const sliceTo = (source, start, end) => {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing region ${start} … ${end}`);
  return source.slice(from, to);
};
/* app.js documents itself heavily, and several comments quote the very strings a removal test
   asserts are gone. Comment-stripped source is what "is it still live code?" has to be asked of. */
const codeOnly = source => source.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/^\s*\/\/.*$/gm, ' ');
const workspaceRig = source => {
  const from = source.indexOf('const WORKSPACE_TEMPLATE_COPY_V97=Object.freeze({');
  const to = source.indexOf('const workspaceTemplateInnerHtmlV97=', from);
  assert.ok(from >= 0 && to > from, 'workspace template machinery not found in this revision');
  return source.slice(from, to);
};

/* The stamp-editor block, from its first constant to the end of the stranded note, evaluated
   verbatim. The saved card length and the gifts are injected because they are the whole question. */
const renderFrom = (source, { stampTarget = 0, gifts = [], canSetupGrow = true, busy = false } = {}) =>
  new Function('snapshot', 'growStampsLevelsSortedV350', 'growStampsRewardAtV410', 'canSetupGrow',
    'growPointsBusyV326', 'CUI', 'esc', 'workspaceLocale', `
    ${workspaceRig(source)}
    ${slice(source, '  const GROW_STAMPS_DEFAULT_LEN_V416=15;', "</div>`:'';")}
    return {growStampsCardLenV416, growStampsTargetV416, growStampsCardLengthBarV416,
      growStampsGridV416, growStampsStrandedNoteV416};`)(
    { loyalty: { stamp_target: stampTarget } },
    gifts.slice().sort((a, b) => Number(a.cost_points || 0) - Number(b.cost_points || 0)),
    new Map(gifts.map(g => [Math.max(0, Number(g.cost_points) || 0), g]).filter(([n]) => n > 0)),
    canSetupGrow, busy, CUI, esc, 'en');
const render = options => renderFrom(appJs, options);

const GIFT = (name, stamps) => ({ id: `r-${stamps}`, customer_name: name, cost_points: stamps });
const cells = markup =>
  [...markup.matchAll(/data-grow-stamps-cell-v416="(\d+)"/g)].map(m => Number(m[1]));
const lenWrites = markup =>
  [...markup.matchAll(/data-grow-stamps-len-v416="(-?\d+)"/g)].map(m => Number(m[1]));
const fieldAttr = (markup, name) => {
  const input = /<input[^>]*data-grow-stamps-lenfield-v422[^>]*>/.exec(markup);
  assert.ok(input, 'the length field is not in this markup');
  const m = new RegExp(`${name}="([^"]*)"`).exec(input[0]);
  return m ? m[1] : null;
};

/* ------------------------------------------------------- R3(a): the maximum is 15 everywhere -- */

test('v463 the typed field declares 15, not 100', () => {
  assert.equal(fieldAttr(render({ stampTarget: 10 }).growStampsCardLengthBarV416, 'max'), '15');
  assert.equal(fieldAttr(render({ stampTarget: 10 }).growStampsCardLengthBarV416, 'min'), '1');
});

test('v463 the "+" stepper is refused at 15 and says why, in the owner\'s own copy', () => {
  const bar = render({ stampTarget: 15 }).growStampsCardLengthBarV416;
  const plus = /<button[^>]*aria-label="One stamp longer"[^>]*>/.exec(bar);
  assert.ok(plus, 'the "+" stepper must still be offered, refused rather than removed');
  assert.match(plus[0], /disabled/);
  assert.match(plus[0], /title="15 stamps is the longest a card can be\."/);
  /* And the visible line, which is the only version a keyboard or a screen reader gets. */
  assert.match(bar,
    /<span class="grow-stamps-lenwhy-v453" id="growStampsLenLongerWhyV453"[^>]*>15 stamps is the longest a card can be\.<\/span>/);
  /* one below the maximum it is free and silent */
  const under = render({ stampTarget: 14 }).growStampsCardLengthBarV416;
  assert.doesNotMatch(/<button[^>]*aria-label="One stamp longer"[^>]*>/.exec(under)[0], /disabled/);
  assert.doesNotMatch(under, /growStampsLenLongerWhyV453/);
});

test('v463 the grid stops offering a trailing "+" at the maximum', () => {
  assert.doesNotMatch(render({ stampTarget: 15 }).growStampsGridV416, /is-add-v416/);
  assert.deepEqual(lenWrites(render({ stampTarget: 15 }).growStampsGridV416), []);
  const under = render({ stampTarget: 14 }).growStampsGridV416;
  assert.match(under, /is-add-v416/);
  assert.deepEqual(lenWrites(under), [15], 'and it offers exactly the maximum, never past it');
});

test('v463 the one-tap stranded fix is withheld for a gift past 15', () => {
  /* v445 withheld this button when the highest gift was past the SERVER bound. The bound moved,
     so the same rule now withholds it for a gift at 20 — a length no owner may set. */
  for (const stamp of [16, 20, 80, 1000]) {
    const note = render({ stampTarget: 10, gifts: [GIFT('Free Lotion', stamp)] }).growStampsStrandedNoteV416;
    assert.match(note, /Stamps past 10 cannot be claimed yet/, `stamp ${stamp} is still reported`);
    assert.deepEqual(lenWrites(note), [], `no fix button for a gift at stamp ${stamp}`);
    assert.match(note, /move that gift onto a stamp inside the card/,
      'the paragraph still names the way out that does exist');
  }
  assert.deepEqual(
    lenWrites(render({ stampTarget: 10, gifts: [GIFT('Free Lotion', 15)] }).growStampsStrandedNoteV416),
    [15], 'a gift at the maximum itself is still one tap from being reachable');
});

test('v463 the length write handler refuses anything above 15 without calling the server', async () => {
  /* The shipped wiring, executed. sb is a recording thenable — Supabase builders are lazy, so a
     stub that is not awaitable would let a missing await pass unnoticed. */
  const wiring = sliceTo(appJs, '  const growStampPublishToastV433=(res,fallback)=>{',
    '  const growPointsAddCancel=');
  const g = render({ stampTarget: 10 });
  const field = { value: '10', onblur: null, onkeydown: null };
  const buttons = lenWrites(g.growStampsCardLengthBarV416 + g.growStampsGridV416)
    .map(value => ({ dataset: { growStampsLenV416: String(value) }, onclick: null }));
  const calls = [];
  const outerMain = {
    querySelectorAll: sel => {
      assert.equal(sel, '[data-grow-stamps-len-v416]');
      return buttons;
    },
    querySelector: sel => {
      assert.equal(sel, '[data-grow-stamps-lenfield-v422]');
      return field;
    },
  };
  const sb = {
    rpc(name, payload) {
      calls.push({ name, payload });
      return { then: resolve => resolve({ data: { publish_status: 'published' }, error: null }) };
    },
  };
  new Function('outerMain', 'sb', 'snapshot', 'S', 'toast', 'growRerenderV322', 'isGrowCurrent',
    'ownerErrorText', 'workspaceTemplateTextV97', 'growStampsCardLenV416',
    'GROW_STAMPS_MAX_LEN_V463', `
    let growPointsBusyV326=false, growPointsErrorV326='';
    ${wiring}
    return {growStampsSetLengthV422};`)(
    outerMain, sb, { loyalty: { stamp_target: 10 } }, { biz: { id: 'biz-1' } }, () => {}, () => {},
    () => true, e => String(e), () => 'saved', 10, 15);

  for (const rejected of ['16', '20', '100', '0', '']) {
    field.value = rejected;
    field.onblur();
    assert.deepEqual(calls, [], `${rejected || '(blank)'} must not reach the server`);
    assert.equal(field.value, '10', 'and the field is restored to the length in force');
  }
  field.value = '15';
  field.onblur();
  assert.deepEqual(calls.map(c => c.payload.p_stamps), [15], 'the maximum itself still writes');
});

/* ------------------------------- R3(a): a card stored longer than 15 is drawn honestly --------- */

test('v463 a legacy card longer than 15 is drawn at its REAL length, never clamped', () => {
  /* Production has none today (scanned 2026-08-23: the highest live stamp_target is 15), but the
     ruling does not migrate existing values, and drawing 15 over a stored 40 would be REG-001
     with the sign reversed — the owner would see 15, the server would hold 40, and one tap would
     write the lie back and strand every gift past 15. */
  const g = render({ stampTarget: 40, gifts: [GIFT('Free Lotion', 30)] });
  assert.equal(g.growStampsCardLenV416, 40);
  assert.equal(cells(g.growStampsGridV416).length, 40);
  assert.equal(fieldAttr(g.growStampsCardLengthBarV416, 'value'), '40',
    'the field states what is stored, and its max attribute states what may be saved');
  assert.equal(fieldAttr(g.growStampsCardLengthBarV416, 'max'), '15');
});

test('v463 an over-maximum card is offered no way to get longer, and a real way to get shorter', () => {
  const bar = render({ stampTarget: 40, gifts: [GIFT('Free Lotion', 30)] }).growStampsCardLengthBarV416;
  const plus = /<button[^>]*aria-label="One stamp longer"[^>]*>/.exec(bar);
  assert.match(plus[0], /disabled/, '41 could only be refused');
  /* "−" would emit 39, which the server refuses just as flatly. It offers the maximum instead —
     the nearest shorter length that can actually be saved — and its label says so rather than
     claiming a single step it is not taking. */
  const minus = /<button[^>]*aria-label="[^"]*"[^>]*>−<\/button>/.exec(bar);
  assert.ok(minus, 'the "−" stepper is still offered');
  assert.match(minus[0], /data-grow-stamps-len-v416="15"/);
  assert.match(minus[0], /aria-label="Shorten to 15 stamps"/);
  assert.doesNotMatch(minus[0], /disabled/);
  assert.doesNotMatch(bar, /data-grow-stamps-len-v416="39"/);
  /* and the ordinary case is untouched: exactly one stamp either side, with the plain label */
  const ordinary = render({ stampTarget: 10 }).growStampsCardLengthBarV416;
  assert.deepEqual(lenWrites(ordinary), [9, 11]);
  assert.match(ordinary, /aria-label="One stamp shorter"/);
  assert.doesNotMatch(ordinary, /Shorten to/);
});

/* ---------------------------------------------------------- R3(b): "+ Add level" is retired --- */

test('v463 the Stamp Card page no longer offers "+ Add level"', () => {
  const page = codeOnly(
    slice(appJs, '    :`<div class="grow-stamps-page-v350">', '${growStampsSummaryV356}'));
  assert.doesNotMatch(page, /\+ Add level/,
    'the button the owner retired must not survive as live markup');
  assert.doesNotMatch(page, /data-grow-points-add-v326/,
    'and neither may any other control on this page open a gift form with no stamp chosen');
  /* Edit settings and the on/off switch beside it are untouched. */
  assert.match(page, /data-grow-points-edit-v326="1">Edit settings</);
  assert.match(page, /data-grow-switchtoggle-v322/);
  /* The POINTS page keeps its own "+ Add reward" — different page, different rule (a points cost
     is not a stamp number), and the shared handler is still wired for it. */
  const points = codeOnly(
    slice(appJs, '  const growPointsManageV326=!canRewards', 'data-grow-points-giftlist-v326>'));
  assert.match(points, /data-grow-points-add-v326="1">\+ Add reward</);
  assert.match(appJs, /outerMain\.querySelectorAll\('\[data-grow-points-add-v326\]'\)/,
    'the handler stays: the points page and its dashed add card still use it');
});

test('v463 the two surviving placement paths both fix the stamp before the form opens', () => {
  const g = render({ stampTarget: 10, gifts: [GIFT('Free Lotion', 40)] });
  /* 1. every slot of the grid */
  assert.deepEqual(cells(g.growStampsGridV416), [1,2,3,4,5,6,7,8,9,10]);
  const cellHandler = sliceTo(appJs, "outerMain.querySelectorAll('[data-grow-stamps-cell-v416]')",
    "  /* nestly_v416: the card's length.");
  assert.match(cellHandler, /growStampsPickedV416=stamp;/);
  /* 2. the v445 stranded chips, which open the gift the owner has to move */
  assert.match(g.growStampsStrandedNoteV416, /data-grow-points-gift-edit-v343="r-40"/);
  const chipHandler = sliceTo(appJs, "outerMain.querySelectorAll('[data-grow-points-gift-edit-v343]')",
    '  /* nestly_v416: tapping a stamp.');
  assert.match(chipHandler, /growPointsEditingV326=id;/);
});

/* The shipped gift-save handler, executed end to end. The only stubs are OUTSIDE the code under
   test: the DOM it reads, a recording thenable for sb (Supabase builders are lazy, so a stub that
   is not awaitable would let a missing await pass unnoticed), and the toast/rerender it calls. */
const saveHandlerSrc = sliceTo(appJs,
  "  const growPointsAddSave=outerMain.querySelector('[data-grow-points-add-save-v326]');",
  '  /* ---- V356: Stamp Card inline row editing');
const attemptSave = async ({ isStamps, points }) => {
  const fields = {
    growPointsAddNameV326: { value: 'Free Kopi' },
    growPointsAddPointsV326: { value: String(points) },
    growPointsAddDescV343: { value: '' },
  };
  const button = { onclick: null };
  const calls = [];
  const state = { error: null };
  const sb = {
    rpc(name, payload) {
      calls.push({ name, payload });
      return { then: resolve => resolve({ data: { publish_status: 'published' }, error: null }) };
    },
  };
  const run = new Function('outerMain', '$', 'sb', 'S', 'growPointsIsStampsV326',
    'GROW_STAMPS_MAX_LEN_V463', 'growPointsSpineIdV326', 'isGrowCurrent', 'ownerErrorText',
    'uploadRewardPhotoV326', 'growStampPublishToastV433', 'toast', 'state', `
    let growPointsBusyV326=false, growPointsErrorV326='', growPointsAddDraftV326={};
    let growPointsEditingV326=null, growPointsPhotoFileV343=null, growPointsRemovePhotoV343=false;
    let growStampsPickedV416=null;
    const growRerenderV322=()=>{state.error=growPointsErrorV326};
    ${saveHandlerSrc}
    return growPointsAddSave.onclick;`)(
    { querySelector: () => button }, id => fields[id], sb, { biz: { id: 'biz-1' } }, isStamps, 15,
    'spine-1', () => true, e => String(e), async () => 'ref', () => {}, () => {}, state);
  await run();
  return { error: state.error, calls };
};

test('v463 the gift form refuses a stamp above the maximum, in plain words', async () => {
  for (const points of [16, 20, 1000]) {
    const { error, calls } = await attemptSave({ isStamps: true, points });
    assert.equal(error,
      `A stamp card is at most 15 stamps long, so a gift cannot sit on stamp ${points}. `
      + 'Choose a stamp between 1 and 15.');
    assert.deepEqual(calls, [], 'a refused gift must not reach the server');
  }
});

test('v463 a stamp inside the maximum still saves, and a points cost is never bounded by 15', async () => {
  /* Inside the maximum but past THIS card's current length is still allowed — that is the v445
     stranded warning's job, and the owner may legitimately place a gift at 12 and then lengthen
     the card to 12, which is exactly what the warning band's one-tap fix offers. */
  for (const points of [1, 12, 15]) {
    const { error, calls } = await attemptSave({ isStamps: true, points });
    assert.equal(error, '', `stamp ${points} must save`);
    assert.deepEqual(calls.map(c => c.name), ['business_create_reward_v326']);
    assert.equal(calls[0].payload.p_points, points);
  }
  /* The POINTS page shares this form, where a redemption cost of 500 is ordinary. A 15 ceiling
     there would be nonsense, so the refusal is scoped to stamps and must not fire. */
  for (const points of [50, 500, 5000]) {
    const { error, calls } = await attemptSave({ isStamps: false, points });
    assert.equal(error, '', `a points cost of ${points} must save`);
    assert.equal(calls[0].payload.p_points, points);
  }
});

/* ----------------------------------------- R3(c): both customer displays wrap at five ---------- */

/* The GEOMETRY is measured in a real browser by tests/browser/verify-v463-customer-stamp-rows.mjs
   (three card lengths x five widths, per-row counts from getBoundingClientRect, its own negative
   control against origin/main which reproduces hero 9/6 and detail 8/7 for a 15-stamp card). That
   needs Chrome, so it cannot run inside `npm test`. What runs here is the pair of declarations
   that harness proves the effect of, plus the guarantee that the harness still exists and still
   covers the widths and card lengths it claims. */
test('v463 both customer stamp displays declare five fixed tracks, like the editor', () => {
  const html = readFileSync(join(root, 'app', 'index.html'), 'utf8');
  /* 1. the red hero card */
  assert.match(html,
    /\.customer-hero-stamp-grid-v422\{display:grid;grid-template-columns:repeat\(5,28px\)/);
  assert.match(html,
    /\.customer-hero-stampcard-v422\.is-compact-v422 \.customer-hero-stamp-grid-v422\{grid-template-columns:repeat\(5,22px\)/,
    'the compact variant too, or a long card would change shape halfway down');
  /* 2. the stamp-card detail */
  assert.match(html,
    /\.customer-programme-stamp-rings\{display:grid;grid-template-columns:repeat\(5,30px\)/);
  /* neither may fall back to a count that follows the container */
  for (const rule of [/\.customer-hero-stamp-grid-v422\{[^}]*\}/, /\.customer-programme-stamp-rings\{[^}]*\}/]) {
    assert.doesNotMatch(rule.exec(html)[0], /auto-fit|auto-fill|flex-wrap/);
  }
  /* 3. and the editor they are matching is unchanged */
  assert.match(html, /\.grow-stamps-editgrid-v416\{display:grid;grid-template-columns:repeat\(5,44px\)/);
  /* Widths: 5x28 + 4x8 = 172, 5x22 + 4x6 = 134, 5x30 + 4x7 = 178 — every one inside the 390px the
     customer shell caps .wallet-inner at, so five tracks can never overflow. */
  assert.ok(5 * 28 + 4 * 8 < 390 && 5 * 22 + 4 * 6 < 390 && 5 * 30 + 4 * 7 < 390);
});

test('v463 the browser geometry harness exists and covers the widths and lengths it claims', () => {
  const harness = readFileSync(
    join(root, 'tests', 'browser', 'verify-v463-customer-stamp-rows.mjs'), 'utf8');
  assert.match(harness, /const WIDTHS=\[390,520,834,1180,1440\]/);
  assert.match(harness, /const CARDS=\[6,12,15\]/);
  assert.match(harness, /NEGATIVE CONTROL/);
  /* It must measure, not read the stylesheet back to itself. */
  assert.match(harness, /getBoundingClientRect/);
  assert.doesNotMatch(harness, /assertTrue\(m\.tracks/);
});

/* -------------------------------------------------------------------- negative control -------- */

test('v463 NEGATIVE CONTROL: these rules do not hold on origin/main', () => {
  const before = gitShow(`${BASE}:app/app.js`);
  assert.match(before, /const GROW_STAMPS_MAX_LEN_V416=100;/,
    'origin/main must still carry the 100 bound; if it does not, re-point this control');
  const g = renderFrom(before, { stampTarget: 15, gifts: [GIFT('Free Lotion', 20)] });
  assert.equal(fieldAttr(g.growStampsCardLengthBarV416, 'max'), '100',
    'the pre-v463 field declared 100');
  assert.match(g.growStampsGridV416, /is-add-v416/,
    'and the pre-v463 grid still offered to lengthen a 15-stamp card');
  assert.deepEqual(lenWrites(g.growStampsStrandedNoteV416), [20],
    'and offered "Make the card 20 stamps", which no owner may now do');
  const overMax = renderFrom(before, { stampTarget: 400 });
  assert.equal(overMax.growStampsCardLenV416, 100,
    'the pre-v463 render clamped a long card to 100 rather than drawing what is stored');
  assert.match(before, /<button type="button" class="btn ghost sm" data-grow-points-add-v326="1">\+ Add level<\/button>/,
    'and "+ Add level" was still on the Stamp Card page');
});
