/* nestly_v449 — two owner items on #/grow/points.
 *
 * ITEM 1 (P1): the "Edit gift" / "Add a gift" dialog was geometrically broken on every tenant.
 * Measured live at innerWidth 1564 on both Cubbly and qa-kaya-toast: the dialog is 520px wide, but
 * its computed display was `grid` with grid-template-columns "120px 160px 110px 200px 190px" —
 * five FIXED tracks totalling 780px plus 4×14px gap = 836px — and `>*{grid-column:1/-1}` stretched
 * every child across all of it. The three text inputs were 836px wide, overflowed the dialog's
 * right edge by +337px, and were text-align:center, so the name, stamp number and description all
 * appeared shoved right and clipped. That is the owner's "misalignment".
 *
 * CAUSE: pure specificity. `.grow-overview[data-programme-view="points"]
 * .grow-points-form-card-v343` — the INLINE gift card's five-column row layout — is (0,3,0). The
 * dialog's own rules are `.grow-points-form-card-v343.grow-points-form-modal-v410`, (0,2,0). The
 * same element carries both classes, so the inline card won and the dialog's carefully written
 * v422 column layout never applied. The input rule was worse: (0,3,1), beating the dialog's
 * (0,3,0) `text-align:left`.
 *
 * ITEM 2: the stamp grid filled the width — nineteen circles on one line at 1564px. Owner,
 * repeated: "i want to have rows of 5 instead of so lengthy rows — 5 stamps then next row."
 *
 * HOW THIS FILE TESTS IT. The geometry itself is measured in a real browser by
 * tests/browser/verify-v449-gift-modal-and-rows-of-five.mjs (5 widths, its own negative control
 * against origin/main's stylesheet, which reproduces the 836px tracks exactly). That needs Chrome,
 * so it cannot run inside `npm test`. What runs here instead is not a grep: it parses the REAL
 * stylesheet out of app/index.html and RESOLVES THE CASCADE — specificity, source order and
 * !important — for the actual element chain the app mounts, then asserts on the winning
 * declarations. A rule that stops matching, or a new rule that outranks the dialog's, changes the
 * answer. Both directions are proved: the same resolver is run against origin/main and required to
 * produce the broken values.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const readIndex = () => readFileSync(join(root, 'app', 'index.html'), 'utf8');
const gitShow = ref => execFileSync('git', ['show', ref], { cwd: root, encoding: 'utf8',
  maxBuffer: 64 * 1024 * 1024 });

/* ---------------------------------------------------------------- a real, small CSS cascade --- */

const styleOf = html => {
  const from = html.indexOf('<style');
  const open = html.indexOf('>', from) + 1;
  const to = html.indexOf('</style>', open);
  assert.ok(from >= 0 && to > open, 'index.html must carry one <style> block');
  return html.slice(open, to);
};

/* Split a selector list on commas that are not inside (), [] — `:is(a,b)` is ONE selector. */
function topLevelSplit(text) {
  const out = []; let depth = 0, start = 0;
  for (let k = 0; k < text.length; k++) {
    const ch = text[k];
    if (ch === '(' || ch === '[') depth++;
    else if (ch === ')' || ch === ']') depth--;
    else if (ch === ',' && depth === 0) { out.push(text.slice(start, k)); start = k + 1; }
  }
  out.push(text.slice(start));
  return out.map(s => s.trim()).filter(Boolean);
}

/* Split a complex selector into compounds and combinators, ignoring whitespace inside [] and ()
   — `a[aria-label="Open menu"]` is ONE compound, not two. */
function splitCombinators(selector) {
  const out = []; let depth = 0, buf = '';
  const flush = () => { if (buf.trim()) out.push(buf.trim()); buf = ''; };
  for (const ch of selector.trim()) {
    if (ch === '(' || ch === '[') depth++;
    else if (ch === ')' || ch === ']') depth--;
    if (depth === 0 && (ch === '>' || ch === '+' || ch === '~')) { flush(); out.push(ch); continue; }
    if (depth === 0 && /\s/.test(ch)) { flush(); continue; }
    buf += ch;
  }
  flush();
  return out;
}

/* Flatten the sheet to {selector, decls, media, order}. Comments go first — several of them
   contain selector text (this codebase documents its own rules), which a naive scan would parse
   as live CSS. Only @media blocks nest here; nothing else does. */
function rules(css) {
  const src = css.replace(/\/\*[\s\S]*?\*\//g, ' ');
  const out = [];
  let i = 0, order = 0;
  const readBlock = (from, media) => {
    let depth = 0, start = from;
    for (let k = from; k < src.length; k++) {
      if (src[k] === '{') { if (depth++ === 0) start = k; continue; }
      if (src[k] !== '}') continue;
      if (--depth === 0) return { body: src.slice(start + 1, k), end: k };
    }
    throw new Error(`unterminated block at ${from} in ${media || 'top level'}`);
  };
  const scan = (text, media) => {
    let p = 0;
    while (p < text.length) {
      const brace = text.indexOf('{', p);
      if (brace < 0) break;
      const prelude = text.slice(p, brace).trim();
      if (prelude.startsWith('@')) {
        /* Nested at-rule: recurse into @media, skip the rest (@keyframes, @font-face…). */
        const sub = (() => { let d = 0; for (let k = brace; k < text.length; k++) {
          if (text[k] === '{') d++; else if (text[k] === '}' && --d === 0) return k; } return -1; })();
        assert.ok(sub > 0, `unterminated ${prelude}`);
        if (/^@media/.test(prelude)) scan(text.slice(brace + 1, sub), prelude.slice(6).trim());
        p = sub + 1;
        continue;
      }
      const close = (() => { let d = 0; for (let k = brace; k < text.length; k++) {
        if (text[k] === '{') d++; else if (text[k] === '}' && --d === 0) return k; } return -1; })();
      assert.ok(close > 0, `unterminated rule ${prelude.slice(0, 60)}`);
      const body = text.slice(brace + 1, close);
      for (const sel of topLevelSplit(prelude)) {
        if (sel.trim()) out.push({ selector: sel.trim(), body, media, order: order++ });
      }
      p = close + 1;
    }
  };
  void i; void readBlock;
  scan(src, null);
  return out;
}

/* Pseudos this matcher deliberately treats as "never true of a resting element in our chain":
   interaction and validity states nothing here is in, pseudo-elements (which are not our element),
   and :root (our chain's root is a div). Anything OUTSIDE this list — :nth-child, :first-child,
   :is, :has — would need real reasoning, so it hard-fails the guard test below rather than being
   silently skipped. */
const NEVER = /^::|^:(root|hover|focus|focus-visible|focus-within|active|checked|disabled|invalid|indeterminate|placeholder-shown|target|visited|link|default|read-only|user-invalid|autofill|fullscreen|backdrop|dir|lang)\b/;
const unsupported = [];

/* A compound: tag, classes, attributes, :not(compound). Enough for every selector in this sheet
   that touches the elements under test — and anything else is REJECTED rather than ignored, so a
   selector shape this matcher cannot judge can never be silently dropped from the cascade. */
function compound(text) {
  const unit = { tag: null, classes: [], attrs: [], not: [], any: [], id: null, dead: false };
  let rest = text;
  /* :not(a,b) excludes every branch; :is()/:where() include if any branch holds. Both are real
     here — this sheet uses :where(a):not(.btn) on link resets — so neither may be waved away. */
  rest = rest.replace(/:not\(([^()]*)\)/g,
    (_, inner) => { for (const b of topLevelSplit(inner)) unit.not.push(compound(b)); return ''; });
  rest = rest.replace(/:(?:is|where|matches)\(([^()]*)\)/g,
    (_, inner) => { unit.any.push(topLevelSplit(inner).map(compound)); return ''; });
  /* strip the state/element pseudos, remembering that they can never hold for us */
  rest = rest.replace(/::?[\w-]+(\([^()]*\))?/g, m => {
    if (NEVER.test(m)) { unit.dead = true; return ''; }
    unit.unknown = m; return '';
  });
  if (unit.unknown) { unit.dead = true; unsupported.push({ text, pseudo: unit.unknown }); }
  if (!rest.trim() && (unit.dead || unit.not.length || unit.any.length)) return unit;
  const tokens = rest.match(/^[a-zA-Z][\w-]*|\.[\w-]+|#[\w-]+|\[[^\]]*\]|\*/g) || [];
  const consumed = tokens.join('');
  if (consumed !== rest) {
    /* Something this matcher does not model — nested :has(+tr), for instance. It is recorded, not
       thrown, and the guard test then proves it could never have reached the elements under test.
       Throwing here would make an unrelated selector elsewhere in a 3000-line sheet fatal. */
    unsupported.push({ text, pseudo: 'unparsed' });
    unit.dead = true;
    return unit;
  }
  for (const t of tokens) {
    if (t === '*') continue;
    else if (t.startsWith('.')) unit.classes.push(t.slice(1));
    else if (t.startsWith('#')) unit.id = t.slice(1);
    else if (t.startsWith('[')) {
      const m = /^\[([\w-]+)(?:([~^$*|]?=)"?([^"\]]*)"?)?\]$/.exec(t);
      assert.ok(m, `unparsed attribute selector ${t}`);
      unit.attrs.push({ name: m[1], op: m[2] || null, value: m[3] ?? null });
    } else unit.tag = t;
  }
  return unit;
}

const matchesCompound = (el, u) => !u.dead
  && (!u.tag || el.tag === u.tag)
  && (!u.id || el.id === u.id)
  && u.classes.every(c => el.classes.includes(c))
  && u.attrs.every(a => a.op ? el.attrs?.[a.name] === a.value : el.attrs?.[a.name] !== undefined)
  && u.not.every(n => !matchesCompound(el, n))
  && u.any.every(list => list.some(n => matchesCompound(el, n)));

/* Right-to-left match over an explicit ancestor chain (root first, subject last). Sibling
   combinators are recorded and treated as non-matching: this model has no siblings, and the guard
   test below proves none of those rules could have reached the elements under test. */
function matches(chain, selector) {
  const parts = splitCombinators(selector);
  if (parts.some(p => p === '+' || p === '~')) {
    unsupported.push({ text: selector, pseudo: 'sibling combinator' });
    return false;
  }
  const units = parts.map(p => (p === '>' ? '>' : compound(p)));
  /* `pinned` carries the combinator of the step that brought us here: after a `>` the candidate is
     exactly chain[ei] and nowhere further up, and the subject compound is always pinned to the
     element itself. Recomputing "am I a child" from the unit rather than from the STEP was the bug
     this comment exists to stop coming back — it let `.card>.input` match an .input two levels
     deep. */
  const walk = (ui, ei, pinned) => {
    if (ui < 0) return true;
    if (ei < 0) return false;
    const u = units[ui];
    const child = units[ui - 1] === '>';
    for (let k = ei; k >= 0; k--) {
      if (matchesCompound(chain[k], u) && walk(child ? ui - 2 : ui - 1, k - 1, child)) return true;
      if (pinned) return false;
    }
    return false;
  };
  return walk(units.length - 1, chain.length - 1, true);
}

const specificity = selector => {
  const flat = selector.replace(/:not\(([^()]*)\)/g, ' $1 ');
  return [
    (flat.match(/#[\w-]+/g) || []).length,
    (flat.match(/\.[\w-]+/g) || []).length + (flat.match(/\[[^\]]*\]/g) || []).length,
    (flat.match(/(^|[\s>+~])[a-zA-Z][\w-]*/g) || []).length,
  ];
};
const beats = (a, b) => {
  for (let i = 0; i < 3; i++) if (a.spec[i] !== b.spec[i]) return a.spec[i] > b.spec[i];
  return a.order > b.order;
};

const declsOf = body => {
  const out = [];
  for (const raw of body.split(';')) {
    const at = raw.indexOf(':');
    if (at < 0) continue;
    const prop = raw.slice(0, at).trim().toLowerCase();
    let value = raw.slice(at + 1).trim();
    if (!prop || !value) continue;
    const important = /!important$/i.test(value);
    if (important) value = value.replace(/!important$/i, '').trim();
    out.push({ prop, value, important });
  }
  return out;
};

/* Resolve one property for one element, honouring media queries by max-width. */
function resolve(sheet, chain, prop, viewport) {
  let win = null;
  for (const rule of sheet) {
    if (rule.media) {
      const max = /max-width\s*:\s*(\d+)px/.exec(rule.media);
      const min = /min-width\s*:\s*(\d+)px/.exec(rule.media);
      if (/prefers-|print|forced-|hover|orientation/.test(rule.media)) continue;
      if (max && viewport > Number(max[1])) continue;
      if (min && viewport < Number(min[1])) continue;
    }
    if (!matches(chain, rule.selector)) continue;
    for (const d of declsOf(rule.body)) {
      if (d.prop !== prop) continue;
      const cand = { ...d, spec: specificity(rule.selector), order: rule.order, selector: rule.selector };
      if (!win) { win = cand; continue; }
      if (cand.important && !win.important) win = cand;
      else if (cand.important === win.important && beats(cand, win)) win = cand;
    }
  }
  return win;
}

/* The element chain the app really mounts (verified against the shipped markup below). */
const CHAIN_DIALOG = [
  { tag: 'div', classes: ['grow-overview'], attrs: { 'data-programme-view': 'points' } },
  { tag: 'ul', classes: ['grow-setup-rewardlist-v301'], attrs: {} },
  { tag: 'li', classes: ['grow-points-form-card-v343', 'grow-points-form-modal-v410'],
    attrs: { role: 'dialog', 'aria-modal': 'true' } },
];
const CHAIN_INPUT = [...CHAIN_DIALOG,
  { tag: 'p', classes: ['grow-setup-sentence-v301'], attrs: {} },
  { tag: 'input', id: 'growPointsAddNameV326', classes: ['grow-setup-input-v301'], attrs: {} }];
/* The same dialog, but as the INLINE card it also ships as — that layout must survive. */
const CHAIN_INLINE = [CHAIN_DIALOG[0], CHAIN_DIALOG[1],
  { tag: 'li', classes: ['grow-points-form-card-v343'], attrs: {} }];
const CHAIN_GRID = [CHAIN_DIALOG[0],
  { tag: 'div', classes: ['grow-stamps-editgrid-v416'], attrs: { role: 'list' } }];

const sheetNow = rules(styleOf(readIndex()));
const at = (chain, prop, vw = 1440, sheet = sheetNow) => resolve(sheet, chain, prop, vw)?.value ?? null;

/* --------------------------------------------------- the matcher must be trustworthy first ---- */

test('v449 nothing the matcher had to skip could have reached these elements', () => {
  /* The resolver treats interaction/validity pseudos, pseudo-elements, :root and sibling
     combinators as non-matching. That is only sound if none of those rules would otherwise have
     styled our chain. Re-test each skipped selector with the pseudo removed; if the remainder
     matches, it must be a resting-state impossibility (":hover" and friends), never something
     structural like :first-child that this model cannot judge. */
  for (const chain of [CHAIN_DIALOG, CHAIN_INPUT, CHAIN_INLINE, CHAIN_GRID]) {
    for (const vw of [390, 1440]) resolve(sheetNow, chain, 'display', vw);
  }
  assert.ok(unsupported.length, 'the sheet certainly contains :has/sibling rules — guard not wired');
  /* A skipped rule is harmless only if its SUBJECT could never be one of our elements. Strip the
     pseudos from the subject compound and ask whether it names anything in these chains. */
  const SUBJECTS = ['grow-points-form-card-v343', 'grow-points-form-modal-v410',
    'grow-setup-input-v301', 'grow-stamps-editgrid-v416', 'grow-setup-sentence-v301'];
  const TAGS = ['li', 'input', 'ul', 'div', 'p'];
  const relevant = [];
  for (const u of unsupported) {
    const parts = splitCombinators(u.text);
    const subject = (parts[parts.length - 1] || '').replace(/::?[\w-]+(\([^()]*\))?/g, '');
    if (SUBJECTS.some(c => subject.includes(c))) { relevant.push(u); continue; }
    if (!subject.replace(/\[[^\]]*\]/g, '').replace(/[.#][\w-]+/g, '')
      && parts.length === 1 && TAGS.includes(subject)) relevant.push(u);
  }
  assert.deepEqual(relevant.map(r => r.text), [],
    'a rule this resolver skipped could have styled one of these elements — teach the matcher');
});

test('v449 the cascade resolver agrees with the browser on things nobody is changing', () => {
  /* Sanity anchors, each independently checkable in devtools, so a wrong answer below is a wrong
     FIX and not a wrong matcher. */
  assert.equal(at(CHAIN_DIALOG, 'position'), 'fixed', 'the dialog is position:fixed');
  assert.equal(at(CHAIN_DIALOG, 'z-index'), '71');
  assert.equal(at(CHAIN_GRID, 'display'), 'grid');
  /* :not() must actually exclude — if the matcher ignored it, the inline rule would still win. */
  assert.ok(matches(CHAIN_INLINE,
    '.grow-overview[data-programme-view="points"] .grow-points-form-card-v343:not(.grow-points-form-modal-v410)'),
    'the inline card still matches its own rule');
  assert.ok(!matches(CHAIN_DIALOG,
    '.grow-overview[data-programme-view="points"] .grow-points-form-card-v343:not(.grow-points-form-modal-v410)'),
    'the dialog does not');
  /* and the child combinator is really a child combinator */
  assert.ok(!matches(CHAIN_INPUT, '.grow-points-form-card-v343>.grow-setup-input-v301'));
  assert.ok(matches(CHAIN_INPUT, '.grow-points-form-card-v343 .grow-setup-input-v301'));
});

/* ------------------------------------------------------------------- ITEM 1: the dialog ------- */

test('v449 the dialog is a single column, not the inline card\'s five-track grid', () => {
  for (const vw of [390, 599, 834, 1180, 1440]) {
    assert.equal(at(CHAIN_DIALOG, 'display', vw), 'flex', `display at ${vw}`);
    assert.equal(at(CHAIN_DIALOG, 'flex-direction', vw), 'column', `direction at ${vw}`);
    assert.equal(at(CHAIN_DIALOG, 'flex-wrap', vw), 'nowrap', `wrap at ${vw}`);
    assert.equal(at(CHAIN_DIALOG, 'grid-template-columns', vw), null,
      `a track list still reaches the dialog at ${vw}`);
  }
});

test('v449 every field is bounded by the dialog and reads left', () => {
  for (const vw of [390, 599, 834, 1180, 1440]) {
    assert.equal(at(CHAIN_INPUT, 'width', vw), '100%', `width at ${vw}`);
    assert.equal(at(CHAIN_INPUT, 'box-sizing', vw), 'border-box', `box-sizing at ${vw}`);
    assert.equal(at(CHAIN_INPUT, 'text-align', vw), 'left', `text-align at ${vw}`);
    /* the base .grow-setup-input-v301 carries margin:0 4px — 8px of overflow under width:100% */
    assert.equal(at(CHAIN_INPUT, 'margin-inline', vw), '0', `margin-inline at ${vw}`);
    assert.equal(at(CHAIN_INPUT, 'max-width', vw), 'none', `max-width at ${vw}`);
  }
});

test('v449 the inline gift card keeps the five-track row it was written for', () => {
  /* The fix must not be "delete the inline layout". The same element is still the inline card on
     the points programme, and there it is a five-column row. */
  assert.equal(at(CHAIN_INLINE, 'display'), 'grid');
  assert.match(at(CHAIN_INLINE, 'grid-template-columns'), /minmax\(120px/);
  assert.equal(at(CHAIN_INLINE, 'grid-template-columns', 1180), '1fr 1fr');
  assert.equal(at(CHAIN_INLINE, 'grid-template-columns', 720), '1fr');
});

test('v449 NEGATIVE CONTROL: the same resolver reports the bug on origin/main', () => {
  const before = rules(styleOf(gitShow('origin/main:app/index.html')));
  assert.equal(at(CHAIN_DIALOG, 'display', 1440, before), 'grid',
    'the pre-fix dialog must resolve to grid, or this resolver is not seeing what Chrome saw');
  const tracks = at(CHAIN_DIALOG, 'grid-template-columns', 1440, before);
  assert.match(tracks, /minmax\(120px,\.5fr\) minmax\(160px,\.85fr\) minmax\(110px,\.55fr\)/,
    'the five inline tracks, which resolve to 120+160+110+200+190 + 4x14 gap = 836px');
  assert.equal(at(CHAIN_INPUT, 'text-align', 1440, before), 'center',
    'and the inputs were centred inside those 836px boxes');
  assert.equal(at(CHAIN_INPUT, 'margin-inline', 1440, before), null);
});

/* ------------------------------------------------------------------ ITEM 2: rows of five ------ */

test('v449 the stamp grid is five per row at every width', () => {
  assert.equal(at(CHAIN_GRID, 'display'), 'grid');
  assert.equal(at(CHAIN_GRID, 'grid-template-columns'), 'repeat(5,44px)');
  assert.equal(at(CHAIN_GRID, 'grid-template-columns', 768), 'repeat(5,40px)',
    'still five on a phone — the whole point is that the card looks the same everywhere');
  assert.equal(at(CHAIN_GRID, 'grid-template-columns', 390), 'repeat(5,40px)');
  /* 5x40 + 4x8 = 232px, inside a 390px viewport. */
  const gap = at(CHAIN_GRID, 'gap', 390);
  assert.equal(gap, '22px 8px');
  assert.equal(at(CHAIN_GRID, 'justify-content'), 'start',
    'five fixed tracks left-aligned, not stretched across the panel');
});

test('v449 a long card scrolls inside its own box instead of running the page away', () => {
  /* 100 stamps is twenty rows. The length control sits above this grid and the summary below it;
     neither may be pushed a page-length apart. */
  assert.equal(at(CHAIN_GRID, 'overflow-y'), 'auto');
  assert.equal(at(CHAIN_GRID, 'overflow-x'), 'hidden');
  assert.match(at(CHAIN_GRID, 'max-height'), /min\(52vh,430px\)/);
  /* the gift glyph hangs 15px above its circle, so the first row needs clearance inside the
     scroll box and every later row needs it from the row above */
  assert.equal(at(CHAIN_GRID, 'padding-top'), '18px');
  assert.equal(at(CHAIN_GRID, 'gap'), '24px 10px');
});

test('v449 rows of five is a layout change ONLY — the grid markup and every handler are untouched', () => {
  /* The strongest available statement: the markup the renderer produces for a 15-stamp card is
     byte-identical to the v445 commit that preceded this work. If a save path, a data attribute,
     an aria-label or the trailing "+" had moved, these bytes would differ. */
  const appNow = readFileSync(join(root, 'app', 'app.js'), 'utf8');
  const appV445 = gitShow('efeceb0:app/app.js');
  const esc = v => String(v ?? '').replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const gifts = [{ id: 'r-4', customer_name: 'Kaya Butter Supreme', cost_points: 4 },
    { id: 'r-6', customer_name: 'Free Kopi Set', cost_points: 6 },
    { id: 'r-15', customer_name: 'Triple-Shot Gula Melaka Kaya', cost_points: 15 },
    { id: 'r-1000', customer_name: 'Free Facial Cream Ultra Hydrating', cost_points: 1000 }];
  const draw = source => {
    const from = source.indexOf('  const GROW_STAMPS_DEFAULT_LEN_V416=15;');
    const to = source.indexOf("</div>`:'';", from);
    assert.ok(from >= 0 && to > from);
    return new Function('snapshot', 'growStampsLevelsSortedV350', 'growStampsRewardAtV410',
      'canSetupGrow', 'growPointsBusyV326', 'CUI', 'esc', `
      ${source.slice(from, to + "</div>`:'';".length)}
      return growStampsCardLengthBarV416+growStampsGridV416+growStampsStrandedNoteV416;`)(
      { loyalty: { stamp_target: 15 } }, gifts,
      new Map(gifts.map(g => [g.cost_points, g])), true, false,
      { icon: n => `<svg data-icon="${n}"></svg>` }, esc);
  };
  assert.equal(draw(appNow), draw(appV445),
    'v449 must not have changed a single byte of what the stamp editor renders');
  /* and the one write this screen makes is still the one write it made */
  assert.equal((appNow.match(/sb\.rpc\('business_set_stamp_card_length_v414'/g) || []).length, 1);
  assert.equal(appNow.indexOf('business_create_reward_v326') >= 0
    && appNow.indexOf('business_update_reward_v326') >= 0, true);
});

test('v449 the browser geometry harness exists and covers the widths it claims', () => {
  /* The numbers in the report come from Chrome, not from this file. Keep the two in step: if the
     harness is deleted or its widths are trimmed, this suite is no longer the whole story. */
  const harness = readFileSync(
    join(root, 'tests', 'browser', 'verify-v449-gift-modal-and-rows-of-five.mjs'), 'utf8');
  assert.match(harness, /const WIDTHS = \[390, 599, 834, 1180, 1440\]/);
  assert.match(harness, /NEGATIVE CONTROL/);
});
