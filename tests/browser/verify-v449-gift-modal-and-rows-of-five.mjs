/* nestly_v449 — two owner items on #/grow/points, measured in a real browser.
 *
 * ITEM 1 (P1). The "Edit gift" / "Add a gift" dialog was geometrically broken on every tenant.
 * Measured live on dcb6a533d42f at 1564px: the dialog is 520px wide, but its computed display was
 * `grid` with grid-template-columns "120px 160px 110px 200px 190px" — the five-track row layout of
 * the INLINE gift card — so its content box resolved to 836px and every direct child, stretched by
 * `>*{grid-column:1/-1}`, was 836px too. The three text inputs overflowed the dialog's right edge
 * by +337px with text-align:center, which is the "misalignment" in the owner's photo.
 *
 * ITEM 2. The stamp grid filled the width (nineteen circles on one line at 1564px). Owner,
 * repeated: five per row, then the next row.
 *
 * WHAT THIS FILE DOES: it builds a page out of the REAL stylesheet from app/index.html and the
 * REAL markup produced by the shipped renderers in app/app.js, mounted under the same
 * `.grow-overview[data-programme-view="points"]` ancestor the app mounts them under — because that
 * ancestor IS the bug — and measures it in Chrome at 390 / 599 / 834 / 1180 / 1440. Nothing is
 * read from source and asserted about; every number below came out of a layout engine.
 *
 * It ends with a NEGATIVE CONTROL: the identical measurements against origin/main's index.html,
 * which must reproduce the 836px overflow and the width-filling grid. A harness that cannot see
 * the bug proves nothing about the fix.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v449-gift-modal-and-rows-of-five.mjs
 */
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const playwright = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const chromium = playwright.chromium || playwright.default?.chromium;
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const WIDTHS = [390, 599, 834, 1180, 1440];
const esc = v => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const CUI = { icon: name => `<svg data-icon="${name}" width="16" height="16"></svg>` };

const styleOf = html => {
  const from = html.indexOf('<style');
  const open = html.indexOf('>', from) + 1;
  const to = html.indexOf('</style>', open);
  if (from < 0 || to < 0) throw new Error('no <style> block in index.html');
  return html.slice(open, to);
};

/* ---- the real renderers, evaluated ---- */

const slice = (start, end, source = appJs) => {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  if (from < 0 || to <= from) throw new Error(`missing region ${start}`);
  return source.slice(from, to + end.length);
};

/* The shipped Add/Edit gift dialog template, with an existing gift on stamp 5 — the state the
   owner and the coordinator both photographed. */
const dialogMarkup = (source = appJs) => new Function(
  'growPointsAddOpenV326', 'growPointsEditingV326', 'growStampsPickedV416', 'growPointsIsStampsV326',
  'growPointsAddDraftV326', 'growPointsPhotoFileV343', 'growPointsCurrentPhotoUrlV343',
  'growPointsErrorV326', 'growPointsBusyV326', 'growPointsDeletePendingV326', 'canSetupGrow',
  'growPointsPhotoPreviewUrlForV349', 'esc', `
  ${slice('  const growPointsAddFormV326=growPointsAddOpenV326===', "</li>`:'';", source)}
  return growPointsAddFormV326;`)(
  'form', 'r-5', 5, true,
  { name: 'Free Kopi Set', points: '5', description: 'One kopi and one kaya toast set, on us.' },
  null, '', '', false, '', true, () => '', esc);

/* nestly_v453: the disabled steppers explain themselves through the workspace copy machinery, so
   the REAL machinery is pulled in with the block rather than stubbed — the sentences this harness
   measures are the sentences the app renders, from the registered copy table. */
const workspaceRig = (source = appJs) => {
  const from = source.indexOf('const WORKSPACE_TEMPLATE_COPY_V97=Object.freeze({');
  const to = source.indexOf('const workspaceTemplateInnerHtmlV97=', from);
  if (from < 0 || to <= from) throw new Error('workspace template machinery not found');
  return source.slice(from, to);
};

/* The shipped stamp grid, 15 stamps with gifts on 4, 6 and 15. */
const gridMarkup = (target, gifts, source = appJs) => new Function(
  'snapshot', 'growStampsLevelsSortedV350', 'growStampsRewardAtV410', 'canSetupGrow',
  'growPointsBusyV326', 'CUI', 'esc', 'workspaceLocale', `
  ${workspaceRig(source)}
  ${slice('  const GROW_STAMPS_DEFAULT_LEN_V416=15;', "</div>`:'';", source)}
  return growStampsCardLengthBarV416+growStampsGridV416+growStampsStrandedNoteV416;`)(
  { loyalty: { stamp_target: target } },
  gifts.slice().sort((a, b) => a.cost_points - b.cost_points),
  new Map(gifts.map(g => [g.cost_points, g])), true, false, CUI, esc, 'en');

const GIFT = (name, stamps) => ({ id: `r-${stamps}`, customer_name: name, cost_points: stamps });
const CARD15 = [GIFT('Kaya Butter Supreme', 4), GIFT('Free Kopi Set', 6),
  GIFT('Triple-Shot Gula Melaka Kaya', 15), GIFT('Free Kopi', 80)];
const CARD12 = [GIFT('Free Kopi Set', 6), GIFT('Kaya Set', 12)];
const CARD100 = [GIFT('Free Kopi Set', 6), GIFT('Century Set', 100)];

/* The page is built from a stylesheet AND a revision of app.js together. The negative control
   below needs BOTH halves of origin/main — v453's stepper defect is caused by markup grouping, so
   a "before" that kept the new markup could not reproduce it. */
const page = (css, source = appJs) => `<!doctype html><html><head><meta charset="utf-8">
<style>${css}</style></head><body>
<div class="wrap" style="padding:16px">
  <div class="grow-overview" data-programme-view="points">
    <div id="card15">${gridMarkup(15, CARD15, source)}</div>
    <div id="card12" hidden>${gridMarkup(12, CARD12, source)}</div>
    <div id="card100" hidden>${gridMarkup(100, CARD100, source)}</div>
    <ul class="grow-setup-rewardlist-v301">${dialogMarkup(source)}</ul>
  </div>
</div></body></html>`;

/* ---- the measurement, run inside the page ---- */

const MEASURE = () => {
  const box = el => { const r = el.getBoundingClientRect(); return { l: r.left, r: r.right, w: r.width, t: r.top, h: r.height }; };
  const dialog = document.querySelector('.grow-points-form-card-v343.grow-points-form-modal-v410');
  const cs = getComputedStyle(dialog);
  const d = box(dialog);
  const pad = { l: parseFloat(cs.paddingLeft), r: parseFloat(cs.paddingRight) };
  const contentRight = d.r - pad.r;
  const children = [...dialog.children].map(el => ({
    tag: el.tagName.toLowerCase(), cls: el.className || '', ...box(el),
  }));
  const inputs = [...dialog.querySelectorAll('.grow-setup-input-v301')].map(el => ({
    id: el.id, textAlign: getComputedStyle(el).textAlign,
    marginLeft: getComputedStyle(el).marginLeft, ...box(el),
  }));
  const rowsOf = id => {
    const host = document.getElementById(id);
    const was = host.hidden; host.hidden = false;
    const grid = host.querySelector('.grow-stamps-editgrid-v416');
    const gcs = getComputedStyle(grid);
    const rows = new Map();
    for (const cell of grid.children) {
      const r = cell.getBoundingClientRect();
      const key = Math.round(r.top);
      rows.set(key, (rows.get(key) || 0) + 1);
    }
    const g = grid.getBoundingClientRect();
    const out = {
      perRow: [...rows.entries()].sort((a, b) => a[0] - b[0]).map(e => e[1]),
      cells: grid.children.length, display: gcs.display, tracks: gcs.gridTemplateColumns,
      width: g.width, right: g.right,
      scrollH: grid.scrollHeight, clientH: grid.clientHeight,
      scrollW: grid.scrollWidth, clientW: grid.clientWidth,
    };
    host.hidden = was;
    return out;
  };
  /* nestly_v453: the length stepper is three controls that must read as one. Measured, not
     assumed: the vertical centres of −, the field and + and their left-to-right order. */
  const lenbar = (() => {
    const host = document.getElementById('card15');
    const was = host.hidden; host.hidden = false;
    const bar = host.querySelector('.grow-stamps-lenbar-v416');
    const minus = bar.querySelector('[aria-label="One stamp shorter"]');
    const field = bar.querySelector('.grow-stamps-lenfield-v422, .grow-stamps-lenvalue-v416');
    const plus = bar.querySelector('[aria-label="One stamp longer"]');
    const mid = el => { const r = el.getBoundingClientRect(); return { c: r.top + r.height / 2, l: r.left, r: r.right }; };
    const out = { minus: mid(minus), field: mid(field), plus: mid(plus),
      barBottom: bar.getBoundingClientRect().bottom,
      why: [...bar.querySelectorAll('.grow-stamps-lenwhy-v453')].map(n => n.textContent.trim()) };
    host.hidden = was;
    return out;
  })();
  return {
    lenbar,
    innerWidth: window.innerWidth,
    dialog: {
      ...d, display: cs.display, tracks: cs.gridTemplateColumns, contentRight,
      scrollW: dialog.scrollWidth, clientW: dialog.clientWidth,
    },
    children, inputs,
    card15: rowsOf('card15'), card12: rowsOf('card12'), card100: rowsOf('card100'),
    docScrollW: document.documentElement.scrollWidth,
    docClientW: document.documentElement.clientWidth,
  };
};

const measureAll = async (browser, css, source = appJs) => {
  const ctx = await browser.newContext();
  const p = await ctx.newPage();
  const out = {};
  for (const width of WIDTHS) {
    await p.setViewportSize({ width, height: 900 });
    await p.setContent(page(css, source), { waitUntil: 'load' });
    out[width] = await p.evaluate(MEASURE);
  }
  await ctx.close();
  return out;
};

/* ---- assertions ---- */

const EPS = 0.5;
const fails = [];
const check = (ok, what) => { if (!ok) fails.push(what); };

const assertFixed = all => {
  for (const width of WIDTHS) {
    const m = all[width];
    const at = s => `@${width}: ${s}`;
    /* ITEM 1 — the dialog is a column, and nothing sticks out of it. */
    check(m.dialog.display === 'flex', at(`dialog display is ${m.dialog.display}, want flex`));
    check(m.dialog.tracks === 'none', at(`dialog still carries grid tracks "${m.dialog.tracks}"`));
    for (const c of m.children) {
      check(c.w <= m.dialog.w + EPS, at(`child ${c.tag}.${c.cls} is ${c.w}px inside a ${m.dialog.w}px dialog`));
      check(c.r <= m.dialog.contentRight + EPS, at(`child ${c.tag}.${c.cls} right ${c.r} > content right ${m.dialog.contentRight}`));
    }
    for (const i of m.inputs) {
      check(i.r <= m.dialog.contentRight + EPS, at(`input #${i.id} right ${i.r} > content right ${m.dialog.contentRight}`));
      check(i.textAlign === 'left', at(`input #${i.id} text-align is ${i.textAlign}, want left`));
      check(parseFloat(i.marginLeft) === 0, at(`input #${i.id} margin-left ${i.marginLeft} pushes it past the content box`));
    }
    check(m.dialog.scrollW <= m.dialog.clientW + EPS,
      at(`dialog scrolls horizontally (${m.dialog.scrollW} > ${m.dialog.clientW})`));
    /* every input shares one right edge — the thing v422 set out to do and never achieved */
    const rights = new Set(m.inputs.map(i => Math.round(i.r)));
    check(rights.size === 1, at(`inputs have ${rights.size} different right edges: ${[...rights]}`));

    /* ITEM 2 — five per row, at every width. */
    check(m.card15.display === 'grid', at(`stamp grid display is ${m.card15.display}`));
    check(m.card15.perRow.every(n => n <= 5), at(`15-card rows are ${m.card15.perRow.join('/')}, want max 5`));
    check(m.card15.perRow.join('/') === '5/5/5/1',
      at(`15-card + trailing "+" should be 5/5/5/1, got ${m.card15.perRow.join('/')}`));
    check(m.card12.perRow.join('/') === '5/5/3',
      at(`12-card + trailing "+" should be 5/5/3, got ${m.card12.perRow.join('/')}`));
    check(m.card15.scrollW <= m.card15.clientW + EPS, at('the stamp grid scrolls horizontally'));
    check(m.card15.scrollH <= m.card15.clientH + EPS,
      at(`a 15-stamp card should not need internal scrolling (${m.card15.scrollH} > ${m.card15.clientH})`));
    /* the long-card guard: 100 stamps stays inside a bounded, internally scrollable box */
    check(m.card100.perRow.every(n => n <= 5), at('100-card row overflowed five'));
    check(m.card100.clientH <= 460, at(`100-card grid is ${m.card100.clientH}px tall — the page runs away`));
    check(m.card100.scrollH > m.card100.clientH, at('100-card grid should scroll internally'));
    /* nestly_v453 — the stepper is one unit at every width. The owner's 390px photo had "−"
       riding up onto the heading's line while "15 stamps +" sat below it. */
    const { minus, field, plus } = m.lenbar;
    check(Math.abs(minus.c - field.c) <= 3,
      at(`"−" centre ${minus.c} vs field ${field.c} — the stepper split across lines`));
    check(Math.abs(plus.c - field.c) <= 3,
      at(`"+" centre ${plus.c} vs field ${field.c} — the stepper split across lines`));
    check(minus.r <= field.l + EPS, at('"−" must sit immediately left of the value it decrements'));
    check(field.r <= plus.l + EPS, at('"+" must sit to the right of the value it increments'));
    /* qa-kaya-toast has a gift on the last stamp, so "−" is refused and must say why */
    check(m.lenbar.why.length === 1,
      at(`expected exactly one refusal sentence, got ${JSON.stringify(m.lenbar.why)}`));
    check(m.lenbar.why[0] === 'A gift sits on stamp 15. Move or remove it to make the card shorter.',
      at(`refusal sentence reads "${m.lenbar.why[0]}"`));
    /* and the page itself never scrolls sideways */
    check(m.docScrollW <= m.docClientW + EPS,
      at(`page scrolls horizontally (${m.docScrollW} > ${m.docClientW})`));
  }
};

const browser = await chromium.launch({
  executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH, args: ['--force-device-scale-factor=1'],
});
try {
  const after = await measureAll(browser, styleOf(readFileSync(join(root, 'app', 'index.html'), 'utf8')));
  assertFixed(after);

  /* NEGATIVE CONTROL — the same page, the pre-fix stylesheet. */
  const show = ref => execFileSync('git', ['show', ref],
    { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const before = await measureAll(browser, styleOf(show('origin/main:app/index.html')),
    show('origin/main:app/app.js'));
  const seen = [];
  for (const width of WIDTHS) {
    const m = before[width];
    if (m.dialog.display === 'grid' && m.children.some(c => c.w > m.dialog.w + EPS)) seen.push(`${width}:dialog`);
    if (m.card15.perRow.some(n => n > 5)) seen.push(`${width}:rows`);
    if (Math.abs(m.lenbar.minus.c - m.lenbar.field.c) > 3
      || Math.abs(m.lenbar.plus.c - m.lenbar.field.c) > 3) seen.push(`${width}:stepper`);
    if (!m.lenbar.why.length) seen.push(`${width}:noreason`);
  }
  if (!seen.length) fails.push('NEGATIVE CONTROL: the pre-fix stylesheet showed neither defect — the harness is blind');

  const brief = w => ({
    dialogW: after[w].dialog.w, dialogDisplay: after[w].dialog.display,
    widestChild: Math.max(...after[w].children.map(c => c.w)),
    inputRightOverflow: Math.round(Math.max(...after[w].inputs.map(i => i.r - after[w].dialog.contentRight))),
    inputTextAlign: after[w].inputs[0].textAlign,
    rows15: after[w].card15.perRow.join('/'), rows12: after[w].card12.perRow.join('/'),
    stepperOneLine: Math.abs(after[w].lenbar.minus.c - after[w].lenbar.field.c) <= 3
      && Math.abs(after[w].lenbar.plus.c - after[w].lenbar.field.c) <= 3,
    card100Height: Math.round(after[w].card100.clientH),
    before: {
      dialogDisplay: before[w].dialog.display, tracks: before[w].dialog.tracks,
      widestChild: Math.max(...before[w].children.map(c => c.w)),
      inputRightOverflow: Math.round(Math.max(...before[w].inputs.map(i => i.r - before[w].dialog.contentRight))),
      inputTextAlign: before[w].inputs[0].textAlign,
      rows15: before[w].card15.perRow.join('/'),
      stepperOneLine: Math.abs(before[w].lenbar.minus.c - before[w].lenbar.field.c) <= 3
        && Math.abs(before[w].lenbar.plus.c - before[w].lenbar.field.c) <= 3,
    },
  });
  console.log(JSON.stringify({
    status: fails.length ? 'FAIL' : 'PASS',
    negativeControlSaw: seen,
    widths: Object.fromEntries(WIDTHS.map(w => [w, brief(w)])),
    failures: fails,
  }, null, 2));
} finally { await browser.close(); }
process.exit(fails.length ? 1 : 0);
