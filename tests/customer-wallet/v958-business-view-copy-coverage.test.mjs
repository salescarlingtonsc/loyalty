/* nestly_v958 — does the business view change language ENTIRELY?
 *
 * v957 added a gate that measured the right direction — what the app RENDERS, against the
 * catalogue — and it passed while an owner was looking at a half-Chinese Business Intelligence
 * page. It scanned MARKUP. Copy does not only live in markup, and the three places it also lives
 * are each invisible to a >literal< scan:
 *
 *   1. CONSTANT TABLES.  BI_WORDING_V892.snapshot is "How your business is doing". It reaches the
 *      DOM as `<h2>${esc(BI_WORDING_V892.snapshot)}</h2>` — one clean text node the walker
 *      translates the moment the catalogue holds it — but it never appears between > and < in the
 *      source, so no harvest ever collected it.
 *   2. SENTENCES BUILT IN JS.  `Only ${best} of ${n} may be sent an offer` is assembled and then
 *      inserted. It renders as ONE text node mixing reviewed English with a runtime value, which a
 *      catalogue keyed on whole nodes can never match. Only a named template reaches it, and
 *      templating it REMOVES the raw literal, so this scan shrinks as the work lands.
 *   3. SINGLE WORDS.  Every harvest I wrote required two words, so "Collected", "Retired" and
 *      "Scheduled" — among the shortest and most-read labels on the page — were skipped by
 *      construction. "3 things to know" was missed by a different rule of mine, which also demanded
 *      a capital letter or a full stop.
 *
 * Every candidate must be translated, or listed in app/i18n/workspace-not-translated-v958.json with
 * a reason. That register is the reviewed record of what is deliberately left in English, and it
 * carries the distinction that matters most here: a default VALUE written into a merchant-owned
 * column is NOT copy. Translating one would write Chinese into a merchant's own records.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const business = readFileSync(new URL('../../app/app-business.js', import.meta.url), 'utf8');
const register = JSON.parse(readFileSync(new URL('../../app/i18n/workspace-not-translated-v958.json', import.meta.url), 'utf8'));

const catalogue = (() => {
  const from = app.indexOf('const WORKSPACE_GENERATED_COPY_V97=');
  const to = app.indexOf('\nconst workspaceTextSourcesV97', from);
  assert.ok(from >= 0 && to > from, 'the generated catalogue must be where the build puts it');
  return app.slice(from, to) + app.slice(app.indexOf('const WORKSPACE_COPY_V97='), from);
})();
const isTranslated = (s) => catalogue.includes(JSON.stringify(s).slice(1, -1) + '":');

const excused = new Map(register.entries.map(e => [e.source, e.reason]));

/* What the JS engine produces from the source's own escapes. Getting this wrong files keys that
   can never match — see tests/customer-wallet/v957-workspace-copy-coverage.test.mjs. */
const asRendered = (raw) => raw
  .replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)))
  .replace(/\\(["'])/g, '$1')
  .replace(/\\n/g, ' ');

const CODE_VALUE = /[<>{}]|\$\{|https?:|^#\/|=eq\.|^sha\d|^[a-z_]+(\.[a-z_]+)+$|^[a-z]+([-_][a-z]+)+$|^[a-z0-9_]+$/;

function constantTableStrings() {
  const found = new Map();
  for (const m of business.matchAll(/([A-Za-z_$][\w$]*)\s*:\s*'((?:[^'\\]|\\.){4,300})'/g)) found.set(m[2], m[1]);
  for (const m of business.matchAll(/([A-Za-z_$][\w$]*)\s*:\s*"((?:[^"\\]|\\.){4,300})"/g)) if (!found.has(m[2])) found.set(m[2], m[1]);
  const out = new Map();
  for (const [raw, holder] of found) {
    const s = asRendered(raw).trim();
    if (!s || s.length > 300) continue;
    if ((s.match(/[A-Za-z][A-Za-z’'-]{1,}/g) || []).length < 2) continue;
    if (CODE_VALUE.test(s)) continue;
    out.set(s, holder);
  }
  return out;
}

function singleWords() {
  const out = new Map();
  const add = (raw, where) => {
    const s = asRendered(raw).trim();
    if (!/^[A-Z][A-Za-z’'-]{2,24}$/.test(s)) return;
    if (!out.has(s)) out.set(s, where);
  };
  for (const m of business.matchAll(/>\s*([^<>\n`]{3,26})\s*</g)) if (!m[1].includes('${')) add(m[1], 'markup');
  for (const m of business.matchAll(/(?:placeholder|title|aria-label|data-label)="([^"`]{3,26})"/g)) if (!m[1].includes('${')) add(m[1], 'attribute');
  for (const m of business.matchAll(/([A-Za-z_$][\w$]*)\s*:\s*'([A-Z][A-Za-z’'-]{2,24})'/g)) add(m[2], m[1]);
  return out;
}

function jsBuiltSentences() {
  const SLOT = /\$\{(?:[^{}`]|\{[^{}`]*\})*\}/g;
  const out = new Map();
  for (const m of business.matchAll(/`((?:[^`\\]|\\.){10,320})`/g)) {
    const raw = m[1];
    if (/[<>]/.test(raw) || !raw.includes('${')) continue;
    const shape = asRendered(raw.replace(SLOT, '{}')).trim();
    if (shape.includes('${')) continue;
    if ((shape.replace(/\{\}/g, ' ').match(/[A-Za-z][A-Za-z’'-]{1,}/g) || []).length < 3) continue;
    if (/select |insert |update | from | where |eq\.|order=|\.js|\.css|http/i.test(shape)) continue;
    if (!out.has(shape)) out.set(shape, raw.slice(0, 120));
  }
  return out;
}

function report(kind, candidates, hint) {
  const missing = [...candidates].filter(([s]) => !isTranslated(s) && !excused.has(s));
  if (missing.length) {
    const lines = missing.slice(0, 25).map(([s, where]) => `  ${where}: ${JSON.stringify(s.slice(0, 110))}`);
    assert.fail(
      `${missing.length} business-view ${kind} still read English for a zh-CN or ms owner.\n${hint}\n`
      + `If a string is NOT copy — a code value, a canvas label, or a default VALUE written into a\n`
      + `merchant-owned column — add it to app/i18n/workspace-not-translated-v958.json with the\n`
      + `reason. Never translate seeded merchant data: it would put Chinese in their records.\n`
      + lines.join('\n')
    );
  }
  return candidates.size;
}

test('copy held in constant tables is translated — the class that left Business Intelligence half English', () => {
  const found = constantTableStrings();
  const total = report('constant-table strings', found,
    'File them in app/i18n/workspace-generated-copy-v97.additions.json — no code change is needed,\n'
    + 'because each renders as a whole text node the walker already reaches.');
  assert.ok(total > 400, `only ${total} constant-table strings were found — the scan has broken, not the copy`);
});

test('single-word labels are translated — the class every two-word harvest skipped', () => {
  const found = singleWords();
  const total = report('single-word labels', found,
    'Check the use site first: a word on a Chart.js axis is painted on canvas and a word in a <td>\n'
    + 'is table data — the walker reaches neither, so those belong in the register, not the ledger.');
  assert.ok(total > 60, `only ${total} single words were found — the scan has broken, not the copy`);
});

/* The third class is the expensive one and it is not finished. A sentence assembled in JS renders as
   ONE text node mixing reviewed English with a runtime value, so it needs a named template AND an
   edit at the site that inserts it — the BI layer escapes these into text nodes, where a template's
   span would show as literal markup. That is real work per call site, not a catalogue entry.

   So this is a ratchet rather than a pass/fail line: templating a sentence REMOVES its raw literal
   from the source, so the count can only fall. It may never rise. A new English sentence built in
   JS pushes it up and fails here, which is the whole point — the class that hid from every previous
   scan is now counted, and counted out loud. */
/* nestly_v959 templated 117 of these. Each one removed its own raw literal from the source, which
   is why the number moved on its own — it is not a figure anyone edited to match. */
const JS_BUILT_SENTENCES_REMAINING_V958 = 200;

test('sentences built in JS are counted, and the count only ever falls', () => {
  const found = jsBuiltSentences();
  const remaining = [...found].filter(([s]) => !isTranslated(s) && !excused.has(s));
  assert.ok(remaining.length <= JS_BUILT_SENTENCES_REMAINING_V958,
    `${remaining.length} JS-built sentences now, up from ${JS_BUILT_SENTENCES_REMAINING_V958}. A sentence\n`
    + `assembled from English and a runtime value can never be reached by a catalogue keyed on whole\n`
    + `text nodes. Give it a named template in WORKSPACE_TEMPLATE_COPY_V97 and render it through\n`
    + `workspaceTemplateHtmlV97 at the call site, or put it in the register with a reason.`);
  assert.equal(remaining.length, JS_BUILT_SENTENCES_REMAINING_V958,
    `${remaining.length} remain — lower the reviewed number to match, and say in the commit which\n`
    + `sentences were templated. Leaving it high would let the next one in unnoticed.`);
});

test('the register says WHY for everything it excuses, and excuses nothing that is already translated', () => {
  for (const entry of register.entries) {
    assert.ok(entry.reason && entry.reason.trim().length > 15,
      `${JSON.stringify(entry.source)} is excused without a reason anyone can check`);
    assert.ok(!isTranslated(entry.source),
      `${JSON.stringify(entry.source)} is BOTH translated and excused — delete the register entry`);
  }
  const sources = register.entries.map(e => e.source);
  assert.equal(new Set(sources).size, sources.length, 'the register lists a string twice');
});
