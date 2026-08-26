/* V243 — Customer Interface becomes a top-level module, plus a customer-app preview.

   Owner (screenshot: the three customer-facing Settings tabs circled, arrow drawn at the LEFT
   NAV): "shift these into a new module (Customer Interface) - where everything that is required
   to edit in customer app must be inside this module", and "i also need a preview of how peekaa
   customer app looks like (to view how their business will look like in the customer app)".

   The contract this file protects is that the move is a MOVE: one implementation of each form,
   reached from the new module, with Settings pointing at it rather than carrying a second copy. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const indexHtml = readFileSync(join(root, 'app', 'index.html'), 'utf8');

function section(source, start, end) {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

/* ------------------------------------------------------------------------------------------
   V448 (REG-009): a real, EXECUTING CSS-cascade check, plus real function execution, for the
   claim the ORIGINAL version of 'V243 the phone frame is a real device mock that still fits a
   390px screen' made by source-regex alone: that the two-column step layout containing the
   phone preview never causes horizontal overflow, and — per the V325 comment above
   ciWithPreviewV325 in app.js — that it "collapses to one column" on narrow viewports. A
   source-regex match on `.split{grid-template-columns:1fr}` inside a @media block proves that
   TEXT exists somewhere in index.html; it does not prove that rule actually wins the cascade at
   any width a browser would use, which is exactly how this file stayed green through a real
   layout bug (REG-003: a second, unconditional `.split{grid-template-columns:1fr 1fr}` rule is
   declared LATER in the file than the @media(max-width:768px) collapse rule, and for two rules
   sharing the same selector text — hence the same specificity — the later one wins the cascade
   at every width, including inside the media query's own range). The walker below is the same
   brace-depth parser tests/business-ui/v440-profile-menu-stacking.test.mjs uses on the real
   <style> block, extended to evaluate whether a media-scoped rule fires at a given viewport
   width (v440 deliberately skips media rules entirely, which is correct for the z-index bug it
   guards but would hide exactly this bug). ------------------------------------------------- */
function parseCssRules(cssText) {
  const text = cssText.replace(/\/\*[\s\S]*?\*\//g, '');
  const rules = [];
  let i = 0;
  const n = text.length;
  function walk(mediaCtx) {
    while (i < n) {
      while (i < n && /\s/.test(text[i])) i++;
      if (i >= n) return;
      if (text[i] === '}') { i++; return; }
      const headerStart = i;
      while (i < n && text[i] !== '{') {
        if (text[i] === '}') { i++; return; }
        i++;
      }
      const header = text.slice(headerStart, i).trim();
      i++; // consume '{'
      if (/^@media|^@supports/.test(header)) {
        walk(header);
      } else if (/^@(-webkit-)?keyframes|^@font-face|^@page/.test(header)) {
        let depth = 1;
        while (i < n && depth > 0) {
          if (text[i] === '{') depth++;
          else if (text[i] === '}') depth--;
          i++;
        }
      } else if (header) {
        const declStart = i;
        let depth = 1;
        while (i < n && depth > 0) {
          if (text[i] === '{') depth++;
          else if (text[i] === '}') depth--;
          if (depth > 0) i++;
        }
        const decl = text.slice(declStart, i);
        i++; // consume the closing '}'
        const selectors = header.split(',').map((s) => s.trim()).filter(Boolean);
        rules.push({ selectors, decl, media: mediaCtx });
      } else {
        i++;
      }
    }
  }
  walk(null);
  return rules;
}

/* Supports exactly the forms this stylesheet uses (`@media(max-width:NNNpx)`, optionally
   combined with a min-width). Not a general media-query engine — a probe for these selectors. */
function mediaAppliesAtWidth(media, width) {
  if (!media) return true;
  const maxMatch = media.match(/max-width:\s*(\d+)/);
  const minMatch = media.match(/min-width:\s*(\d+)/);
  if (maxMatch && width > Number(maxMatch[1])) return false;
  if (minMatch && width < Number(minMatch[1])) return false;
  return true;
}

function parseDeclarations(decl) {
  const props = {};
  for (const part of decl.split(';')) {
    const colon = part.indexOf(':');
    if (colon < 0) continue;
    const prop = part.slice(0, colon).trim();
    const value = part.slice(colon + 1).trim();
    if (prop) props[prop] = value;
  }
  return props;
}

/* The effective declared properties for one EXACT selector TEXT at one viewport width. Rules
   firing at that width are merged in SOURCE ORDER, later overwriting earlier property-by-
   property — the correct cascade result for rules that share selector text (and therefore
   specificity), which is the case for every selector this file probes below. */
function effectiveDeclarations(rules, selectorText, width) {
  const props = {};
  for (const rule of rules) {
    if (!rule.selectors.includes(selectorText)) continue;
    if (!mediaAppliesAtWidth(rule.media, width)) continue;
    Object.assign(props, parseDeclarations(rule.decl));
  }
  return props;
}

const indexStyleBlock = section(indexHtml, '<style>', '</style>');
const cssRules = parseCssRules(indexStyleBlock);

/* A top-level `function NAME(){...}` whose closing brace sits alone at column 0 — the same
   extraction convention tests/business-ui/v439-add-staff-single-surface.test.mjs documents and
   relies on for this codebase. */
function extractFunction(src, name) {
  const startRe = new RegExp(`^function ${name}\\(`, 'm');
  const m = startRe.exec(src);
  assert.ok(m, `extractFunction: missing function ${name}`);
  const rest = src.slice(m.index);
  const lines = rest.split('\n');
  const acc = [];
  for (const line of lines) {
    acc.push(line);
    if (line === '}') return acc.join('\n');
  }
  throw new Error(`extractFunction: no column-0 closing brace found for ${name}`);
}

/* An indented `const NAME=...;` arrow-function assignment (ciWithPreviewV325 lives inside
   customerInterfacePageV243, not at column 0). Same "read lines until one trims to end with
   ';'" rule v439's extractConst uses for its top-level consts, tolerant of leading indentation. */
function extractIndentedConst(src, name) {
  const lines = src.split('\n');
  const startIdx = lines.findIndex((l) => l.trim().startsWith(`const ${name}=`));
  assert.ok(startIdx >= 0, `extractIndentedConst: missing const ${name}`);
  const acc = [];
  for (let i = startIdx; i < lines.length; i++) {
    acc.push(lines[i]);
    if (lines[i].trim().endsWith(';')) return acc.join('\n');
  }
  throw new Error(`extractIndentedConst: unterminated const ${name}`);
}

const settings = section(app, 'async function settingsPage()', '/* ---------- billing (read-only) ---------- */');
const page = section(app, 'async function customerInterfacePageV243(hashParam)', '/* ---------- phone country-code picker');
const sections = section(app, 'function customerInterfaceSectionsHtmlV243(', 'function wireCustomerInterfaceV243(');
const wiring = section(app, 'function wireCustomerInterfaceV243(', 'async function customerInterfacePageV243(hashParam)');
const preview = section(app, 'function customerInterfacePreviewCardHtmlV243(', 'function wireCustomerInterfacePreviewV243(');

/* ------------------------------------------------ (a) the rail entry and the route both exist */

test('V243 Customer Interface is a top-level rail entry beside Programmes', () => {
  const groups = app.match(/const NAVGROUPS=\[[\s\S]*?\n\];/)[0];
  /* V296 retarget (owner: "please make sub-tab under 'Customer Interface'"): the entry is still
     a top-level rail entry directly after Programmes, but it is now a GROUP with routable
     children instead of a flat link — the same shape V294 gave Programmes. */
  /* V334 (owner markup, photo 9: hide Preview/Done/Customer programme from nav): the sidebar now
     maps the filtered VISIBLE list, not the full array — routes/hashes stay intact elsewhere. */
  assert.match(groups, /\{key:'customerui',icon:'customers',label:'Customer Interface',items:\['customer-interface'\],\s*views:CUSTOMER_INTERFACE_VIEWS_VISIBLE_V334\.map\(view=>\[view\[1\],view\[2\],view\[3\]\]\)\}/);
  const order = [...groups.matchAll(/\{key:'([a-z]+)'/g)].map((m) => m[1]);
  assert.equal(order[order.indexOf('grow') + 1], 'customerui', 'it sits directly after Programmes');
});

test('V243 the rail entry resolves to a routed page function', () => {
  // navHtml renders a flat group as #/<items[0]>, so the module key IS the hash.
  assert.match(app, /'customer-interface':customerInterfacePageV243\}/);
  assert.match(app, /async function customerInterfacePageV243\(hashParam\)\{/);
  // V296: the bare '#/customer-interface' still lands on the page's first view.
  /* V368: the requested view is normalised first (the retired 'interface' hash now resolves to
     Customer Action, where its content moved), then matched against the same list. */
  assert.match(app, /const customerInterfaceViewV296=CUSTOMER_INTERFACE_VIEWS_V296\.some\(view=>view\[0\]===ciRequestedViewV368\)/);
  assert.match(app, /const ciRequestedViewV368=String\(hashParam\|\|''\)==='interface'\?'actions':String\(hashParam\|\|''\);/);
});

test('V243 the workspace chunk classifier no longer swallows every "#/customer…" hash', () => {
  /* '#/customer' as a bare prefix matched '#/customer-interface' too, which would have sent a
     workspace route to the customer chunk and cost a whole-bundle self-heal on every visit. */
  assert.match(app, /const CUSTOMER_ROUTE_PREFIXES_V185=\['#\/b\/','#\/customer\/','#\/wallet','#\/claim','#\/join','#\/offer\/','#\/local\/customer-preview'\];/);
  const prefixes = app.match(/const CUSTOMER_ROUTE_PREFIXES_V185=\[([^\]]+)\]/)[1];
  const inline = indexHtml.match(/var customer=\[([^\]]+)\]/)[1];
  assert.equal(inline, prefixes, 'the inline preloader must mirror the router rule');
});

/* ------------------------------- (b) the module reuses the functions Settings used, not copies */

test('V243 the module hosts the sign-up QR and customer-app switches through the same loaders', () => {
  /* V368 (owner markup, photo 2: the QR card arrowed into the profile menu, renamed "My Business
     QR"). The QR left this page for the account menu's dialog, so the loader is called from
     there — with a host — and this page loads only the capabilities card. Still ONE loader and
     one definition of the card, which is what this test exists to protect. */
  assert.match(wiring, /loadCustomerCapabilitiesV223\(\);/);
  assert.doesNotMatch(wiring, /loadSignupConfig\(\);/);
  assert.match(app, /loadSignupConfig\(\$\('businessQrHostV368'\)\)/);
  assert.match(app, /<b>My Business QR<\/b>/);
  assert.match(sections, /id="businessCustomerCapabilities"/);
  // V296: the re-render callback carries the open sub-tab so add/retire returns to it.
  assert.match(page, /wireCustomerInterfaceV243\(\(\)=>customerInterfacePageV243\(hashParam\)\)/);
  // One definition of each, still where it always was.
  assert.equal((app.match(/async function loadSignupConfig\(host\)/g) || []).length, 1);
  assert.equal((app.match(/async function loadCustomerCapabilitiesV223\(\)/g) || []).length, 1);
});

test('V243 the module hosts the customer programme editor through the same v95 loader', () => {
  assert.match(page, /id="customerProgrammeEditorV95"/);
  assert.match(page, /loadCustomerProgrammePresentationEditorV95\(\);/);
  assert.equal((app.match(/async function loadCustomerProgrammePresentationEditorV95\(\)/g) || []).length, 1);
});

test('V375 the CSV import still lives on Customers, once; the fields editor is gone', () => {
  /* V368 (owner ruling: move, don't delete): the importer moved to Customers, where bringing in
     a customer list belongs. Still exactly one copy of its markup and its wiring.
     V375 (owner, photo 16): the Customer fields card beside it was struck through and deleted,
     so this test no longer expects it anywhere. */
  assert.match(app, /function customerCsvImportCardHtmlV368\(\)/);
  assert.match(app, /function wireCustomerCsvImportV368\(\)/);
  assert.match(app, /staff_create_client/);
  assert.equal((app.match(/<b>Customer fields<\/b>/g) || []).length, 0, 'the fields editor is deleted');
  assert.equal((app.match(/<b>Import customers \(CSV\)<\/b>/g) || []).length, 1);
  assert.equal((app.match(/function wireCustomerCsvImportV368\(\)/g) || []).length, 1);
});

/* V259 SUPERSEDES this expectation. The owner drew arrows from ALL THREE Settings tabs —
   Workspace & brand included — onto the Customer Interface nav item, so "linked, not moved" is no
   longer the instruction. The form still may not be FORKED: it moved whole, one definition, one
   #bsave handler. tests/business-ui/v259-points-provenance-and-brand-move.test.mjs owns the full
   contract; this file keeps the part it was already guarding — that Settings never grows a second
   copy of the form. */
test('V259 Workspace & brand moved to Customer Interface as ONE form with ONE save', () => {
  assert.doesNotMatch(settings, /id="bsave"/, 'Settings must not carry a second copy of the form');
  assert.doesNotMatch(settings, /<label for="bc">Brand colour/);
  assert.match(page, /\$\{workspaceBrandPanelHtmlV259\(\)\}/);
  /* V375 (owner, photo 17: "remove"): the brand colour picker is gone from the form. The form is
     still ONE form with ONE save, which is what this test guards; the booking policy field is the
     marker that it travelled whole. */
  /* V385 (owner, photo 12): the booking policy moved to Appointment Setting, so it is no longer
     this form's marker. The registered company name is — it is the field V259 kept here on the
     "one interleaved form, one save" reasoning, and it is still behind the same single #bsave. */
  assert.match(app, /<label for="blegal">Registered company name \(for receipts\)<\/label>/);
  assert.doesNotMatch(app, /<label for="bp">Booking policy \(shown on your portal\)<\/label>/,
    'the booking policy belongs to Appointment Setting now');
  assert.equal((app.match(/id="bp"/g) || []).length, 1, 'exactly one booking policy field, on one page');
  assert.doesNotMatch(app, /<label for="bc">Brand colour/);
  assert.equal((app.match(/id="bsave"/g) || []).length, 1, 'exactly one Workspace & brand form');
  assert.equal((app.match(/\$\('bsave'\)\.onclick=/g) || []).length, 1, 'exactly one save handler');
});

/* -------------------------------------------- (c) Settings points at it instead of duplicating */

/* V269 SUPERSEDES the "tabs stay visible" half: the owner circled the three tabs and wrote
   "delete these from settings". The surviving contract is that Settings holds only the three
   operations tabs and no pointer card. tests/business-ui/v269-* owns the full V269 contract. */
test('V269 the moved tabs and their pointer cards are gone from Settings', () => {
  const tabs = section(app, 'class="settings-tabs" data-workspace-i18n', '</div>\n    <section class="settings-panel" id="setpanel-modules"');
  const order = [...tabs.matchAll(/data-settab="([a-z]+)"/g)].map((m) => m[1]);
  assert.deepEqual(order, ['modules', 'catalogue', 'team']);
  assert.doesNotMatch(app, /settingsMovedToCustomerInterfaceCardV243/);
  assert.doesNotMatch(app, /Moved to Customer Interface in the main menu\./);
});

test('V243 Settings no longer renders or wires the moved forms', () => {
  for (const gone of [
    /id="signupWrap"/, /id="businessCustomerCapabilities"/, /id="csvf"/, /id="cfAdd"/,
    /<b>Customer fields<\/b>/, /loadSignupConfig\(\)/, /loadCustomerCapabilitiesV223\(\)/,
    /client_field_definitions/,
  ]) assert.doesNotMatch(settings, gone, `Settings still carries ${gone}`);
});

/* ------------------------------------------------------------------ (d) the customer preview */

/* V326 SUPERSEDES the iframe contract. Owner report (2026-08-15): the phone frame rendered
   blank in production. Root cause: app/vercel.json sends `frame-ancestors 'none'` +
   `X-Frame-Options: DENY` — a deliberate anti-clickjacking header that refuses to let this app
   frame itself on ANY page, including its own public portal, so the iframe could never have
   painted in production regardless of same-origin same-tab logic. Rather than weaken that header
   sitewide, the preview now renders the customer-facing markup directly — no iframe, nothing to
   be blocked, nothing to detect. */
test('V326 the preview renders customer-facing markup inline — no iframe, no CSP dependency', () => {
  assert.doesNotMatch(preview, /<iframe/, 'an iframe here would hit the same frame-ancestors wall the old preview did');
  assert.match(preview, /<div class="customer-preview-phone-v243"><div class="customer-preview-screen-v243 ci-live-preview-body-v326">\$\{customerInterfaceLivePreviewMarkupV326\(\)\}<\/div><\/div>/);
  assert.match(app, /function customerInterfaceLivePreviewMarkupV326\(\)\{/);
  assert.match(page, /wireCustomerInterfacePreviewV243\(\);/);
});

test('V326 the live preview reflects the CURRENT form values, not last-saved state', () => {
  const wire = section(app, 'function wireCustomerInterfacePreviewV243(', 'function customerInterfaceSectionsHtmlV243(');
  assert.match(wire, /refreshCustomerInterfaceLivePreviewV326\(\);/);
  /* V385: the industry select and its customer-facing wording feed the identity line under the
     business name in the preview, so they refresh it too. */
  assert.match(wire, /\['bn','bc','bp','bbio','bilabel','bi'\]\.forEach\(id=>\{/);
  assert.match(wire, /el\.addEventListener\('input',refreshCustomerInterfaceLivePreviewV326\)/);
  const markup = section(app, 'function customerInterfaceLivePreviewMarkupV326(', 'function refreshCustomerInterfaceLivePreviewV326(');
  // Reads the live input value, falling back to saved state only when the field isn't on screen.
  assert.match(markup, /\$\('bn'\)\?\.value\|\|S\.biz\.name/);
  /* V375: there is no colour to read any more — every customer surface uses Peekaa's accent. */
  assert.match(markup, /CUSTOMER_SURFACE_ACCENT_V375/);
});

/* V327 (owner, screenshot of the real wallet — tier, points, rewards, bottom nav — "must tally
   100%"). V327 asserted the OPPOSITE of the line below: at the time, bio was not referenced
   anywhere in the wallet render path, so reading it here would have previewed a field production
   never displayed. nestly_v417 changed the fact — customerBusinessTaglineV385 puts the bio under
   the business name in the wallet — and the owner's 2026-08-21 photo 4 marks its ABSENCE from
   this preview as the defect ("should reflect the actual customer app, because it still has
   missing fields like Company bio"). So the rule is inverted, deliberately: every field the
   shared wallet render reads must be passed in, and the test now guards that instead.
   V334 (owner markup, photo 10: "why this not reflected?"): booking policy is the one exception —
   it IS shown to real customers elsewhere (booking confirmation, appointment detail rows), so the
   owner's ask to see it preview here is honoured by reading it directly, as its own note beneath
   the wallet render rather than by widening customerMerchantExperienceMarkupV95's signature. */
test('V327 the preview calls the REAL wallet render function, not a hand-rolled lookalike', () => {
  const markup = section(app, 'function customerInterfaceLivePreviewMarkupV326(', 'function customerInterfacePreviewSideCardHtmlV325(');
  assert.match(markup, /customerMerchantExperienceMarkupV95\(\{/);
  assert.match(markup, /customerPrimaryNavigation\('programmes',\{\}\)/);
  assert.match(markup, /bio:\(\$\('bbio'\)/, 'the wallet shows the bio since v417, so the preview must carry it');
  assert.match(markup, /gallery:Array\.isArray\(businessProfileExtrasV418/, 'and the v418 gallery');
  assert.match(markup, /social_links:Array\.isArray\(businessProfileExtrasV418/, 'and its links');
  assert.match(markup, /\$\('bp'\)\?\.value\|\|S\.biz\.booking_policy/, 'booking policy IS previewed now, read live like name/brandColor above');
  // The sample numbers are clearly labelled, not presented as if they were a real customer's.
  /* nestly_v417 (owner, photo 11: the preview ringed — "sync to live reward programmes"). Which
     programmes appear, and whether they count points or stamps, come off the spine now; only the
     CUSTOMER is still invented, because a preview has nobody in it. The badge says which half is
     which rather than disclaiming the whole thing. */
  /* nestly_v541 (owner, photo 2, the real app beside the preview: "there's no rewards in actual
     customer app — why did you add it in?"). The badge changed with the section it described. The
     preview passes rewardsHost:false, so the real renderer correctly draws NO reward list — and
     v327 had bolted an invented one on at the bottom, at a position the customer app never uses.
     With that gone the preview is the owner's live input plus the customer app's own renderer,
     and the line now says that instead of promising a sample customer's balance and tier. */
  assert.match(markup, /Your business profile as customers see it, drawn by the customer app/);
  assert.ok(!markup.includes('aria-label="Sample rewards"'),
    'the preview must not invent a rewards section the customer app never renders there');
  assert.match(app, /programmes:programmeSpineRowsV314\(\)/);
});

test('V243 the preview points at the PUBLIC slug page, same-origin and relative', () => {
  const url = section(app, 'function customerInterfacePreviewUrlV243(', 'function customerInterfacePreviewCardHtmlV243(');
  // location.pathname keeps it same-origin on production, previews and the native WebView alike.
  assert.match(url, /return `\$\{location\.pathname\}#\/b\/\$\{encodeURIComponent\(String\(S\.biz\?\.slug\|\|''\)\)\}`;/);
  assert.doesNotMatch(url, /https?:\/\/|publicAppUrl/, 'no absolute host, and no tokened QR link');
  // A join token would be consumed by opening it; the slug page is safe to render repeatedly.
  assert.doesNotMatch(preview, /join\?token=/);
});

/* V327 SUPERSEDES the V326 copy: the card now shows the WALLET (post-join), not the pre-join
   public page, so its own label must say so — the old sentence would now describe a screen the
   card no longer renders. */
test('V327 the preview is honestly labelled for the screen it actually shows, and openable full size', () => {
  assert.match(preview, /<b>Preview the customer app<\/b>/);
  /* nestly_v421: the second half of that sentence became untrue in v417 and the owner marked it
     in photo 4. The card now describes what the preview actually renders. */
  assert.match(preview, /This is the wallet a customer reaches by clicking into your firm — their name for you, your bio, your photos and links, and their tier, points and rewards\./);
  // The link still opens the REAL public page (a normal top-level navigation, unaffected by
  // frame-ancestors) — distinguishing it from the inline preview above, which is a re-render of
  // sample wallet data, not a live page at all.
  assert.match(preview, /<a class="btn ghost sm" id="customerAppPreviewOpenV243" href="\$\{esc\(previewUrl\)\}" target="_blank" rel="noopener noreferrer">Open your public page \(real page, new tab\)<\/a>/);
});

test('V243 the phone frame is a real device mock that still fits a 390px screen', () => {
  assert.match(preview, /<div class="customer-preview-phone-v243"><div class="customer-preview-screen-v243 ci-live-preview-body-v326">/);
  assert.match(indexHtml, /\.customer-preview-phone-v243\{[^}]*width:390px;max-width:100%/);
  assert.match(indexHtml, /\.customer-preview-screen-v243\{[^}]*height:640px;max-height:70vh;[^}]*overflow-y:auto/);
  // The workspace page must never scroll sideways because of it.
  assert.match(indexHtml, /\.settings-page,\.settings-page \.split,\.settings-page \.card\{[^}]*min-width:0[^}]*max-width:100%/s);
  assert.match(page, /<div class="settings-page" data-workspace-i18n>/);
});

/* --------------------------------------------------------------------------------------------
   V448 (REG-009): the same claim as the test just above, EXECUTED. The three tests below replace
   what used to be regex string-matches with (1) a real cascade resolution of the actual <style>
   block, at the widths a phone or a narrow browser window would report, and (2) real execution of
   ciWithPreviewV325 / customerInterfacePreviewSideCardHtmlV325 (extracted from app.js, run in a
   vm sandbox — nothing under test is stubbed except the wallet-content renderer these functions
   call into, which the nesting claim does not depend on). This is "no scope growth": it covers
   exactly what the test above already claims (the phone frame fits, the page never scrolls
   sideways) — it just proves the claim by running the code instead of grepping its source. ---- */

test('sanity: the CSS cascade walker actually resolves values already known to be true, at a representative width', () => {
  // Guards against the walker silently matching nothing and every test below passing vacuously
  // because effectiveDeclarations() always returns {}.
  const desktopSplit = effectiveDeclarations(cssRules, '.split', 1200);
  assert.equal(desktopSplit.display, 'grid');
  assert.ok(desktopSplit['grid-template-columns'], 'expected the walker to find a grid-template-columns declaration for .split');
});

test('V243/V325 EXECUTING: at a narrow width, the two-column step layout actually collapses to one column', () => {
  // The V325 comment directly above ciWithPreviewV325 in app.js claims: `.split`, "the grid this
  // business console already collapses to one column at <=900px". 600px sits inside every
  // candidate breakpoint named anywhere near this code (768 in the actual @media rule, 900 in
  // that comment, 960 in the unrelated V295 comment about .c360-summary-card-v294) — so if the
  // collapse works at all, it must be in effect here.
  const narrow = effectiveDeclarations(cssRules, '.split', 600);
  assert.equal(narrow['grid-template-columns'], '1fr',
    'REG-003: a later, UNCONDITIONAL `.split{grid-template-columns:1fr 1fr}` rule is declared '
    + 'after the `@media(max-width:768px){.split{grid-template-columns:1fr}}` collapse rule. Both '
    + 'share the selector text `.split`, so they share specificity, and the later one wins the '
    + 'cascade at every width — including inside the media query\'s own range. The two-column '
    + 'step layout (form beside the 390px-wide phone preview) never actually stacks, which is the '
    + 'measured REG-003 symptom (a preview phone rendering far narrower than 390px). A prior '
    + 'source-regex version of this test could not see this: the collapsing declaration IS '
    + 'present in the file, just permanently overridden.');
});

test('V243/V325 EXECUTING: the settings-page containment rules really do win the cascade (no sideways scroll), at every width', () => {
  for (const width of [390, 600, 1440]) {
    const settingsSplit = effectiveDeclarations(cssRules, '.settings-page .split', width);
    assert.equal(settingsSplit['min-width'], '0', `.settings-page .split min-width at ${width}px`);
    assert.equal(settingsSplit['max-width'], '100%', `.settings-page .split max-width at ${width}px`);
    const phone = effectiveDeclarations(cssRules, '.customer-preview-phone-v243', width);
    assert.equal(phone['max-width'], '100%', `.customer-preview-phone-v243 max-width at ${width}px`);
  }
});

test('V243/V325 EXECUTING: ciWithPreviewV325 really nests the form and the phone-preview frame inside ONE .split', () => {
  const previewSideCardSrc = extractFunction(app, 'customerInterfacePreviewSideCardHtmlV325');
  const ciWithPreviewSrc = extractIndentedConst(app, 'ciWithPreviewV325');
  // Only the wallet-content renderer is stubbed: the nesting under test (which div wraps which)
  // does not depend on what customer data is inside the phone screen.
  // `const` bindings from a vm-executed script are NOT exposed as properties on the sandbox
  // object afterward (a vm/eval scoping quirk, unlike `var`/`function`), so the call has to
  // happen inside the SAME script — its return value is what runInNewContext hands back.
  const sandbox = { customerInterfaceLivePreviewMarkupV326: () => '<div id="stubWalletMarkup"></div>' };
  const html = vm.runInNewContext(
    `${previewSideCardSrc}\n${ciWithPreviewSrc}\nciWithPreviewV325('<form id="stubStepForm"></form>');`,
    sandbox
  );
  assert.equal(typeof html, 'string', 'extraction must have produced a callable ciWithPreviewV325 returning a string');

  assert.match(html, /^<div class="split ci-step-layout-v325">/,
    'the wrapper the CSS cascade tests above measure (.split) must be the outermost element');
  const mainIdx = html.indexOf('class="ci-step-main-v325"');
  const previewColIdx = html.indexOf('class="ci-step-preview-v325"');
  assert.ok(mainIdx >= 0 && previewColIdx > mainIdx, 'the form column must precede the preview column');
  const phoneIdx = html.indexOf('class="customer-preview-phone-v243"');
  const screenIdx = html.indexOf('class="customer-preview-screen-v243');
  assert.ok(phoneIdx > previewColIdx, 'the 390px phone frame must be nested inside .ci-step-preview-v325');
  assert.ok(screenIdx > phoneIdx, 'the scrollable screen must be nested inside the phone frame');
  assert.match(html, /stubStepForm/, 'the caller\'s form markup must actually be rendered, not replaced');
  assert.match(html, /stubWalletMarkup/, 'the live-preview content renderer must actually be called, not skipped');
});

/* ---------------------------------------------------------- (e) access gating matches Settings */

test('V243 the module is owner-only on exactly the terms Settings is', () => {
  // Route guard: hiding the rail link is not a boundary — anyone can type the hash.
  assert.match(app, /if\(pageKey==='customer-interface'&&S\.myRole!=='owner'\)\{\s*\n\s*toast\('Only the owner can open Customer Interface\.'\);\s*\n\s*return nav\('#\/dashboard'\);/);
  assert.match(app, /if\(pageKey==='settings'&&S\.myRole!=='owner'\)\{/);
  // Rail visibility, on the same terms as the other owner-only structural surface.
  const nav = app.slice(app.indexOf('const navModuleVisible='), app.indexOf('const visGroups='));
  assert.match(nav, /\|\|\(m==='customer-interface'&&S\.myRole==='owner'\)/);
  // And the page itself renders read-only rather than an editor for anyone else.
  assert.match(page, /const canEditCustomerInterface=S\.myRole==='owner';/);
  assert.match(page, /if\(!canEditCustomerInterface\)return;/);
  assert.match(page, /Only the owner can change what customers see\./);
});
