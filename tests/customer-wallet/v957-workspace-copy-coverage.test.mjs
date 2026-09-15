/* nestly_v957 — does the business view ACTUALLY change language?
 *
 * The workspace localiser has been correct since v97 and the catalogue has grown for thirty waves,
 * and an owner still switched the language nine times and settled back on English. Nothing was
 * broken. The catalogue simply did not reach two thirds of what they were reading, and no test
 * asked whether it did: every gate until now counted what the catalogue CONTAINS, never what the
 * workspace RENDERS. A catalogue can grow forever and cover less.
 *
 * So this measures the other direction. It walks the shipped business bundle for the strings the
 * workspace puts on screen and asserts each one is either translated or on a named list with a
 * reason. Add an English aria-label to a workspace page and this fails.
 *
 * The two decodings below are the defect class this wave was mostly made of. A text node holds what
 * the BROWSER and the ENGINE have already decoded — `&amp;` is an ampersand, `—` is an em dash,
 * `\'` is an apostrophe — while the catalogue was being written from how app.js SPELLS them. File a
 * key in its encoded form and it looks reviewed and matches nothing, silently, for ever.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const business = readFileSync(new URL('../../app/app-business.js', import.meta.url), 'utf8');

const catalogue = (() => {
  const from = app.indexOf('const WORKSPACE_GENERATED_COPY_V97=');
  const to = app.indexOf('\nconst workspaceTextSourcesV97', from);
  assert.ok(from >= 0 && to > from, 'the generated catalogue must be where the build puts it');
  return app.slice(from, to) + app.slice(app.indexOf('const WORKSPACE_COPY_V97='), from);
})();
const isTranslated = (s) => catalogue.includes(JSON.stringify(s).slice(1, -1) + '":');

/* What the DOM will actually hold, after the HTML parser and the JS engine have both had it. */
const asRendered = (raw) => raw
  .replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)))
  .replace(/\\(["'])/g, '$1')
  .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
  .replace(/&quot;/g, '"').replace(/&#39;/g, "'")
  .replace(/&ldquo;/g, '“').replace(/&rdquo;/g, '”').replace(/&rsquo;/g, '’')
  .replace(/&middot;/g, '·').replace(/&mdash;/g, '—')
  .replace(/&nbsp;/g, ' ').replace(/&hellip;/g, '…');

/* Source that leaked through the `> … <` window from inside a JS expression. Not copy, not a bug. */
const LOOKS_LIKE_CODE = new RegExp([
  /\$\('|\.innerHTML|Number\.|const |if\(|selectedOptions|dataset\.|prompt\(|\.value/,
  /===|!==|&&|\|\||=>|\?'|':|\)\)|\)\{|\.join\(|\.repeat\(|\.indexOf\(/,
  /[{}]$|^[=<>)}\]!]|^\W+$|#\//,
  /[A-Za-z_$][\w$]*\([A-Za-z_$'"]/,   // an identifier called as a function; real copy puts a space before "("
].map(r => r.source).join('|'));

/* Drawn before anyone has said which language they read: there is no preference to follow yet, so
   these are a product decision (a pre-sign-in picker), not copy anyone forgot to file. */
const BEFORE_SIGN_IN = new Set([
  'renderOnboard', 'manualBusinessApplicationFallbackHtml', 'loadSignupConfig',
  'renderBusinessApplication', 'renderAuth', 'renderBusinessDemoRequest',
  'renderStaffInviteAuthV151', 'renderBusinessSignupChoice', 'renderPasswordUpdate',
  'renderRecoveryInvalid', 'renderNativeBusinessCompanion', 'previewStaffInviteV151',
  'staffInvitePreviewMarkupV151', 'businessGoogleButtonHtml', 'startBusinessGoogleAuth',
  'startPlatformGoogleAuth'
]);

/* Left in English on purpose, each for its own reason. */
const NEVER_TRANSLATED = new Map([
  ['Bahasa Melayu', 'a language picker names every language the way its own speakers write it'],
  ['admin.peekaa@gmail.com', 'an address, not a sentence'],
  ['name@example.com', 'an address, not a sentence'],
  ['name&#9;phone&#9;email&#10;Jane Tan&#9;9123 4567&#9;jane@mail.com',
   'a CSV template the owner pastes into a spreadsheet — the header words are the file format'],
]);

const enclosingFunction = (() => {
  const spans = [...business.matchAll(/^(?:async )?function ([A-Za-z0-9_$]+)\s*\(/gm)]
    .map(m => ({ name: m[1], at: m.index }));
  return (position) => {
    let name = '(top level)';
    for (const span of spans) { if (span.at <= position) name = span.name; else break; }
    return name;
  };
})();

function harvest(pattern) {
  const found = new Map();
  for (const match of business.matchAll(pattern)) {
    const raw = match[1];
    if (raw.includes('${') || raw.includes('`')) continue;          // interpolated: a template's job
    const rendered = asRendered(raw).trim();
    if (!rendered || rendered.length > 300) continue;
    if (LOOKS_LIKE_CODE.test(rendered)) continue;
    if ((rendered.match(/[A-Za-z][A-Za-z’'-]{1,}/g) || []).length < 2) continue;
    const fn = enclosingFunction(match.index);
    if (BEFORE_SIGN_IN.has(fn)) continue;
    if (!found.has(rendered)) found.set(rendered, fn);
  }
  return found;
}

const textNodes = harvest(/>([^<>\n`]{4,300})</g);
const attributes = harvest(/(?:placeholder|title|aria-label|data-label)="([^"`]{4,200})"/g);

function report(kind, found) {
  const missing = [...found].filter(([s]) => !isTranslated(s) && !NEVER_TRANSLATED.has(s));
  if (missing.length) {
    const lines = missing.slice(0, 25).map(([s, fn]) => `  ${fn}: ${JSON.stringify(s.slice(0, 110))}`);
    assert.fail(
      `${missing.length} workspace ${kind} still render English for a zh-CN or ms owner.\n`
      + `File them in app/i18n/workspace-generated-copy-v97.additions.json (and register the wave in\n`
      + `tests/customer-wallet/v465-workspace-copy-generator.test.mjs), or add one to NEVER_TRANSLATED\n`
      + `here with the reason. Remember the key is what the DOM HOLDS — entities and \\u escapes\n`
      + `already decoded — not how app.js spells it.\n${lines.join('\n')}`
    );
  }
  return found.size;
}

test('every sentence the signed-in workspace renders is translated, or says why it is not', () => {
  const total = report('text nodes', textNodes);
  assert.ok(total > 1500, `only ${total} workspace text nodes were found — the harvest has broken, not the copy`);
});

test('every aria-label, title, placeholder and data-label the workspace renders is translated too', () => {
  /* These were the two-thirds. The walker has always translated all four attributes; nothing ever
     collected them, so a screen-reader user read English while the visible page turned. */
  const total = report('attributes', attributes);
  assert.ok(total > 250, `only ${total} workspace attributes were found — the harvest has broken, not the copy`);
});

test('the decoding this gate depends on matches what a browser and the engine actually produce', () => {
  /* If asRendered() drifts, both tests above pass while filing keys nothing can match — the exact
     failure this wave existed to clean up. Pin it. */
  assert.equal(asRendered('Date &amp; time'), 'Date & time');
  assert.equal(asRendered('kept \\u2014 they simply stop'), 'kept — they simply stop');
  assert.equal(asRendered("Customers won\\'t see"), "Customers won't see");
  assert.equal(asRendered('&ldquo;Show on booking page&rdquo;'), '“Show on booking page”');
  /* And each of those really is filed in the decoded form, not the encoded one. */
  assert.ok(isTranslated('Date & time'), 'the decoded form is the catalogue key');
  assert.ok(!isTranslated('Date &amp; time'), 'the encoded form must never be a catalogue key');
});
