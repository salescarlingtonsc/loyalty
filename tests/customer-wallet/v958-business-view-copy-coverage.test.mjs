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
/* nestly_v960 templated another 232. The number moves on its own — templating a sentence removes
   its raw literal — so it is measured, never edited to match. What is left is what a pair cannot
   express: sentences assembled from sub-clauses that are themselves assembled, and three carrying
   two INDEPENDENT plural conditions, which need four keys rather than two. Nine shapes the scan
   was counting are not copy at all — a localStorage key, three CSS selectors, three PostgREST
   strings, a storage URL, and one window that opened mid-expression — and are in the register. */
/* nestly_v961 closed the class. The last 21 were the ones a single pair could not express: four
   sentences carrying two INDEPENDENT plural conditions (four keys each, chosen by a nested ternary
   at the call site, because pluralV774 takes the English noun as an ARGUMENT and a value is
   preserved verbatim — translating the noun alone would have left Chinese mid-English); two
   multi-line sentences whose \n is part of the copy; and the rest single-shape. Zero is now the
   line: any new English sentence assembled in JS fails here on the next commit. */
const JS_BUILT_SENTENCES_REMAINING_V958 = 0;

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

/* ── nestly_v961: a FOURTH class, found while reviewing this wave's own rows ──────────────────
   The three classes above are about where copy LIVES. This one is about how it is PARAMETERISED.

   `${count} ${count===1?'stamp':'stamps'}` is not a sentence assembled in JS by the scan above's
   definition — it carries fewer than three English words — but it has the identical failure. The
   noun sits in a VALUE, and a template value is preserved verbatim, so it survives into 中文 the
   moment the sentence around it is localised. That is precisely how "Annual计费从 … 开始" was
   about to ship: billingCadenceWordV764 returns an English word and the sentence took it as a
   slot. Three of these were fixed in v961 because this wave touched them; the rest are counted
   here so the class cannot quietly grow while the catalogue does.

   The fix is never a helper tweak — translating the noun alone leaves Chinese mid-English until
   the surrounding sentence is templated too. It is key VARIANTS chosen at the call site, the same
   shape v961 used for the two-independent-plural sentences.

   THIS NUMBER IS A FLOOR, NOT A CENSUS. The scan pairs backticks sequentially, so a template
   literal nested inside another (`${own?'':` for ${units} ${units===1?'branch':'branches'}`}`)
   is swallowed by the outer one and never counted. Lowering it is real work; it rising means a
   new one was added in plain sight. */
/* nestly_v962 closed the nine business-surface shapes whose template literal was the whole
   expression — a drop-in replacement with no restructuring, so no render path changed shape.
   What is left is deliberately left, and each has a reason rather than a shrug:

   FOUR ARE ON THE CUSTOMER SURFACE (the wallet's own point/stamp nouns, the consent history
   sentence, and the stamps-left column). workspaceTemplateTextV97 defaults its locale to
   workspaceLocale, and the customer reads customerLocale — so converting these means threading
   the customer's locale through the helper at every call and deciding whether the v954 walker
   re-runs its render on a language change the way v959 made the workspace route do. That is a
   design decision about the customer surface, not a find-and-replace, and it belongs in a wave
   that can verify it end to end.

   FOUR ARE NESTED INSIDE A LARGER TEMPLATE LITERAL, where converting the noun means restructuring
   the sentence around it — the capacity-increase confirm and the branch-count line among them.
   Note the scan cannot even SEE those: it pairs backticks sequentially, so an inner literal is
   swallowed by its outer one. The count is a floor. */
const NOUN_AS_VALUE_REMAINING_V961 = 8;

/* Not copy. Each is a ternary over two English words that never reaches a reader as prose. */
const NOUN_AS_VALUE_NOT_COPY_V961 = new Map([
  ['t{}:{}:{}', 'a telemetry token — matched/unmatched is a field value, not a word anyone reads'],
  ['data-stamp-quest-claimed-v323="{}"', 'an HTML data attribute; yes/no is read by code, never rendered'],
  ['{}.{}', 'a file extension — png/jpg is the format, not a word'],
  ['{}', 'the ternary picks a TEMPLATE KEY, not a word: this one is already right'],
  ['{}-customer-intelligence-{}.csv', 'a download filename; the scope word names the file, and a\n'
    + 'localised filename would break every operator script that globs for it'],
]);

function nounAsValueShapes() {
  const SLOT = /\$\{(?:[^{}`]|\{[^{}`]*\})*\}/g;
  const WORD_TERNARY = /\?\s*['"]([A-Za-z][A-Za-z ]{0,20})['"]\s*:\s*['"]([A-Za-z][A-Za-z ]{0,20})['"]/;
  const out = new Map();
  for (const m of app.matchAll(/`((?:[^`\\]|\\.){4,400})`/g)) {
    const raw = m[1];
    if (/[<>]/.test(raw) || !raw.includes('${')) continue;
    for (const slot of raw.match(SLOT) || []) {
      const pair = slot.match(WORD_TERNARY);
      if (!pair) continue;
      const shape = raw.replace(SLOT, '{}').trim();
      if (!out.has(shape)) out.set(shape, `${pair[1]}/${pair[2]}`);
    }
  }
  return out;
}

test('an English noun is never left sitting in a template value, and the count only ever falls', () => {
  const found = nounAsValueShapes();
  const remaining = [...found].filter(([shape]) => !NOUN_AS_VALUE_NOT_COPY_V961.has(shape));
  assert.ok(remaining.length <= NOUN_AS_VALUE_REMAINING_V961,
    `${remaining.length} shapes now, up from ${NOUN_AS_VALUE_REMAINING_V961}. A word chosen by a\n`
    + `ternary and handed to a sentence as a VALUE is preserved verbatim — it will read English\n`
    + `inside an otherwise Chinese or Malay sentence. Give the call site key variants in\n`
    + `WORKSPACE_TEMPLATE_COPY_V97 instead, one per form of the word. If the pair is not copy — a\n`
    + `field value, a file extension, a template KEY — add it to NOUN_AS_VALUE_NOT_COPY_V961 with\n`
    + `the reason.\n`
    + remaining.map(([shape, pair]) => `  ${pair.padEnd(22)} ${JSON.stringify(shape)}`).join('\n'));
  assert.equal(remaining.length, NOUN_AS_VALUE_REMAINING_V961,
    `${remaining.length} remain — lower the reviewed number to match.`);
});

test('the not-copy register for noun-as-value says why, and excuses nothing that is still rendered', () => {
  const found = nounAsValueShapes();
  for (const [shape, reason] of NOUN_AS_VALUE_NOT_COPY_V961) {
    assert.ok(reason.trim().length > 20, `${JSON.stringify(shape)} is excused without a real reason`);
    assert.ok(found.has(shape),
      `${JSON.stringify(shape)} is excused but no longer exists — drop it, or the register starts\n`
      + `excusing things nobody can find. A stale excuse is how the next one gets in.`);
  }
});

/* ── nestly_v963: being IN the reviewed table is not the same as being translated ──────────────
   The worst version of the noun-as-value defect is the one that looks finished. Nine named
   templates — reviewed, in all three locales, counted by every gate above — took the inflecting
   word as a VALUE:

     showingSalesPaymentStateNotApplied  {saleWord}  'sale'/'sales'
     billingCycleNotOfferedAtThisCapacity {cycle}    'Annual'/'Monthly'
     referralsCouldNotBeTurnedOnOff      {onOff}     'on'/'off'
     enterHowManyUnitsCustomerNeedsForThisTier {unit} 'visits'/'points'   … and five more

   A value is preserved verbatim, so a zh-CN owner read "显示 3 笔销售sales · …" — the Chinese
   sentence had already said 笔销售 and then appended the English word — and "此容量不提供Annual
   付款方式". These shipped. No count in this file could see them, because every count here asks
   whether a string is IN the catalogue, and they were.

   So this gate asks the opposite question, at the call site: is any value handed to a named
   template an English WORD chosen by a ternary? That is a defect on sight. The fix is one key per
   form of the word, which is why the nine slot-bearing rows were deleted rather than left beside
   their replacements — a row with a {word} slot is a template for making the mistake again.

   Zero is the line, and it is a real zero, not a ratchet: there is no legitimate reason to put an
   English word in a value. A NAME, a number, a date, a merchant's own words — those are values. */
function nounShapedTemplateSlots() {
  const found = [];
  const call = /workspaceTemplate(?:Text|Html|Attribute)V97\(/g;
  let m;
  while ((m = call.exec(app))) {
    let i = m.index + m[0].length, depth = 1, args = '';
    for (; i < app.length && depth > 0; i++) {
      const c = app[i];
      if (c === '(') depth++;
      else if (c === ')') { depth--; if (!depth) break; }
      args += c;
    }
    const open = args.indexOf('{', args.indexOf(','));
    if (open < 0) continue;
    let d = 1, values = '';
    for (let j = open + 1; j < args.length && d > 0; j++) {
      const c = args[j];
      if (c === '{') d++;
      else if (c === '}') { d--; if (!d) break; }
      values += c;
    }
    for (const hit of values.matchAll(
      /([A-Za-z_][A-Za-z0-9_]*)\s*:\s*[^,]*?\?\s*['"]([A-Za-z][A-Za-z ]{0,20})['"]\s*:\s*['"]([A-Za-z][A-Za-z ]{0,20})['"]/g)) {
      found.push({
        line: app.slice(0, m.index).split('\n').length,
        slot: hit[1], pair: `${hit[2]}/${hit[3]}`,
        key: (args.match(/^\s*['"]([A-Za-z0-9_]+)['"]/) || [])[1] || '(computed)',
      });
    }
  }
  return found;
}

test('no named template is handed an English word as a value — the defect that hides inside a reviewed row', () => {
  const found = nounShapedTemplateSlots();
  assert.deepEqual(found, [],
    `${found.length} named template call${found.length === 1 ? '' : 's'} pass an English word as a\n`
    + `VALUE. A value is preserved verbatim, so the word stays English inside the Chinese or Malay\n`
    + `sentence — and the row still counts as translated everywhere else in this file. Split the key\n`
    + `into one per form of the word and delete the slot-bearing row.\n`
    + found.map(f => `  app.js:${f.line}  ${f.key} {${f.slot}} <- ${f.pair}`).join('\n'));
});

test('no row in the reviewed template table still carries a word-shaped slot', () => {
  /* The call-site check above is the one that bites; this is its other half. A slot NAMED for a
     word is the invitation — {saleWord}, {onOff}, {cycle}, {unit} — and leaving one in the table
     is how the next call site learns to pass one. */
  const table = app.slice(app.indexOf('const WORKSPACE_TEMPLATE_COPY_V97=Object.freeze({'));
  const WORD_SHAPED = /\{(\w*(?:Word|onOff|cycle|cadence|unit|state|plural)\w*)\}/i;
  /* Two slots are named after a word and hold something else. Both were checked at their call
     site rather than taken on trust — that is the price of an allow-list. */
  const NOT_A_WORD = new Map([
    ['lastVisitCadenceValue', 'its {cadence} is a NUMBER of days — String(Math.round(cadence_days)) —\n'
      + 'rendered between "~" and "d". A number is a value in any language.'],
    ['usuallyVisitsEveryDaysLastSeenDaysAgo', 'its {cadenceDays} is a NUMBER of days, rendered\n'
      + 'between "every" and "days" — the noun is already in the reviewed sentence.'],
    ['customerUsuallyVisitsEveryDaysLastSeenDaysAgo', 'same: {cadenceDays} is a day count, not a word.'],
    ['mostlyCrowdOnlySomeBuyersGaveDetailsTooFew', 'CROWD PHRASE — a real gap, deliberately left.'],
    ['mostlyCrowdTooFewBuyersGaveDetails', 'CROWD PHRASE — a real gap, deliberately left.'],
    ['mostlyCrowdSomeOfBuyers', 'CROWD PHRASE — a real gap, deliberately left.'],
    ['mostBuyersOfItemAre', 'CROWD PHRASE — a real gap, deliberately left. {crowdWords} is built one\n'
      + 'layer down as `${genderWord} aged ${ageWord}` from two demographic words, so closing it means\n'
      + 'keying gender x age-band and rebuilding that phrase, not splitting these four rows. Counted\n'
      + 'here rather than excused quietly: the owner reads "大多是 women aged 25-34" today.'],
    ['unitsCountTowardMembership', 'its {unit} is ct(presentation.unit): the CUSTOMER translator has\n'
      + 'already turned it into the reader\'s own language before it reaches the slot. The open\n'
      + 'question on this row is the other one — the template resolves against workspaceLocale while\n'
      + 'the wallet reads customerLocale — and that is the customer-surface wave, not this defect.'],
  ]);
  const offenders = [];
  for (const row of table.matchAll(/^ {2}([A-Za-z0-9_]+):Object\.freeze\(\{en:("(?:[^"\\]|\\.)*")/gm)) {
    const hit = JSON.parse(row[2]).match(WORD_SHAPED);
    if (hit && !NOT_A_WORD.has(row[1])) offenders.push(`${row[1]} carries {${hit[1]}}`);
  }
  for (const key of NOT_A_WORD.keys()) {
    assert.ok(table.includes(`\n  ${key}:Object.freeze({`),
      `${key} is allow-listed here but no longer exists — drop the entry rather than leaving an\n`
      + `excuse nobody can check.`);
  }
  assert.deepEqual(offenders, [],
    `a reviewed template still has a slot named for a word rather than a value:\n  `
    + offenders.join('\n  '));
});

/* The name-independent half. Two of the worst offenders in this wave were invisible to both scans
   above: tiersAreEarnedByNowYour* named its basis {v1} and {v3}, and cardCustomersSeeIsThisLong
   took "8 stamps" built whole by a helper. Neither slot NAME looks like a word and neither call
   site shows a quoted pair — the word came out of a function.

   So this asks the third question: is a known word-producing helper ever handed to a template as
   a value? These functions all RETURN English ('stamps', 'Annual', '3 points'). Their output
   belongs in a key name, never in a slot. */
const WORD_PRODUCING_HELPERS_V963 = [
  'billingCadenceWordV764', 'tillUnitNounV430', 'unitWord', 'pluralV774', 'biPluralV892',
  'growPointsUnitV326', 'rewardUnit', 'unitNounV437', 'unitNounV430',
];

test('no word-producing helper is ever handed to a named template as a value', () => {
  const offenders = [];
  const call = /workspaceTemplate(?:Text|Html|Attribute)V97\(/g;
  let m;
  while ((m = call.exec(app))) {
    let i = m.index + m[0].length, depth = 1, args = '';
    for (; i < app.length && depth > 0; i++) {
      const c = app[i];
      if (c === '(') depth++;
      else if (c === ')') { depth--; if (!depth) break; }
      args += c;
    }
    const open = args.indexOf('{', args.indexOf(','));
    if (open < 0) continue;
    let d = 1, values = '';
    for (let j = open + 1; j < args.length && d > 0; j++) {
      const c = args[j];
      if (c === '{') d++;
      else if (c === '}') { d--; if (!d) break; }
      values += c;
    }
    for (const helper of WORD_PRODUCING_HELPERS_V963) {
      if (!new RegExp(`\\b${helper}\\b`).test(values)) continue;
      offenders.push(`app.js:${app.slice(0, m.index).split('\n').length}  ${helper} feeds a template value`);
    }
  }
  assert.deepEqual(offenders, [],
    `a helper that RETURNS an English word is being passed to a template as a value. Its output is\n`
    + `preserved verbatim, so it stays English inside the Chinese or Malay sentence. Pick the key by\n`
    + `the same condition the helper switches on, and give each form its own reviewed row.\n`
    + offenders.join('\n'));
});

test('the word-producing helper list still names functions this app has', () => {
  /* An allow-list that drifts is worse than none: if a helper is renamed, the check above silently
     stops looking for it. */
  for (const helper of WORD_PRODUCING_HELPERS_V963) {
    assert.ok(new RegExp(`\\b${helper}\\b`).test(app),
      `${helper} is checked for but no longer exists in app.js — rename it here or drop it.`);
  }
});
