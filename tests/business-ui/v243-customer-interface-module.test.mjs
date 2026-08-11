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

const settings = section(app, 'async function settingsPage()', '/* ---------- billing (read-only) ---------- */');
const page = section(app, 'async function customerInterfacePageV243()', '/* ---------- phone country-code picker');
const sections = section(app, 'function customerInterfaceSectionsHtmlV243(', 'function wireCustomerInterfaceV243(');
const wiring = section(app, 'function wireCustomerInterfaceV243(', 'async function customerInterfacePageV243()');
const preview = section(app, 'function customerInterfacePreviewCardHtmlV243(', 'function wireCustomerInterfacePreviewV243(');

/* ------------------------------------------------ (a) the rail entry and the route both exist */

test('V243 Customer Interface is a top-level rail entry beside Programmes', () => {
  const groups = app.match(/const NAVGROUPS=\[[\s\S]*?\n\];/)[0];
  assert.match(groups, /\{key:'customerui',icon:'customers',flat:'Customer Interface',items:\['customer-interface'\]\},/);
  const order = [...groups.matchAll(/\{key:'([a-z]+)'/g)].map((m) => m[1]);
  assert.equal(order[order.indexOf('grow') + 1], 'customerui', 'it sits directly after Programmes');
});

test('V243 the rail entry resolves to a routed page function', () => {
  // navHtml renders a flat group as #/<items[0]>, so the module key IS the hash.
  assert.match(app, /'customer-interface':customerInterfacePageV243\}/);
  assert.match(app, /async function customerInterfacePageV243\(\)\{/);
});

test('V243 the workspace chunk classifier no longer swallows every "#/customer…" hash', () => {
  /* '#/customer' as a bare prefix matched '#/customer-interface' too, which would have sent a
     workspace route to the customer chunk and cost a whole-bundle self-heal on every visit. */
  assert.match(app, /const CUSTOMER_ROUTE_PREFIXES_V185=\['#\/b\/','#\/customer\/','#\/wallet','#\/claim','#\/join'\];/);
  const prefixes = app.match(/const CUSTOMER_ROUTE_PREFIXES_V185=\[([^\]]+)\]/)[1];
  const inline = indexHtml.match(/var customer=\[([^\]]+)\]/)[1];
  assert.equal(inline, prefixes, 'the inline preloader must mirror the router rule');
});

/* ------------------------------- (b) the module reuses the functions Settings used, not copies */

test('V243 the module hosts the sign-up QR and customer-app switches through the same loaders', () => {
  assert.match(wiring, /loadSignupConfig\(\);\s*\n\s*loadCustomerCapabilitiesV223\(\);/);
  // The hosts those loaders write into come from the lifted markup, not a second copy.
  assert.match(sections, /<div class="card" id="signupWrap">/);
  assert.match(sections, /id="businessCustomerCapabilities"/);
  assert.match(page, /wireCustomerInterfaceV243\(customerInterfacePageV243\)/);
  // One definition of each, still where it always was.
  assert.equal((app.match(/async function loadSignupConfig\(\)/g) || []).length, 1);
  assert.equal((app.match(/async function loadCustomerCapabilitiesV223\(\)/g) || []).length, 1);
});

test('V243 the module hosts the customer programme editor through the same v95 loader', () => {
  assert.match(page, /id="customerProgrammeEditorV95"/);
  assert.match(page, /loadCustomerProgrammePresentationEditorV95\(\);/);
  assert.equal((app.match(/async function loadCustomerProgrammePresentationEditorV95\(\)/g) || []).length, 1);
});

test('V243 the customer fields and CSV import moved with their panel, once', () => {
  assert.match(sections, /<b>Customer fields<\/b>/);
  assert.match(sections, /<b>Import customers \(CSV\)<\/b>/);
  assert.match(wiring, /create_client_field_definition/);
  assert.match(wiring, /staff_create_client/);
  // add/retire re-render the page they now live on, not Settings.
  assert.match(wiring, /toast\('Customer field added'\);rerender\(\);/);
  assert.equal((app.match(/<b>Customer fields<\/b>/g) || []).length, 1, 'one copy of the form');
  assert.equal((app.match(/<b>Import customers \(CSV\)<\/b>/g) || []).length, 1);
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
  assert.match(app, /<label for="bc">Brand colour \(used on your portal\)<\/label>/);
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

test('V243 the preview iframe is lazy — no src until the card is opened', () => {
  assert.match(preview, /<details class="card customer-preview-v243" id="customerAppPreviewV243"/);
  assert.match(preview, /<iframe id="customerAppPreviewFrameV243" data-preview-src="\$\{esc\(previewUrl\)\}"/);
  assert.doesNotMatch(preview, /<iframe[^>]*\ssrc=/, 'a src in the markup would load on every visit');
  assert.match(preview, /loading="lazy"/);
  const wire = section(app, 'function wireCustomerInterfacePreviewV243(', 'function customerInterfaceSectionsHtmlV243(');
  assert.match(wire, /card\.ontoggle=\(\)=>\{/);
  assert.match(wire, /if\(!card\.open\|\|frame\.getAttribute\('src'\)\)return;/);
  assert.match(wire, /frame\.setAttribute\('src',frame\.dataset\.previewSrc\|\|''\);/);
  assert.match(page, /wireCustomerInterfacePreviewV243\(\);/);
});

/* A blank rectangle with no explanation is the one outcome this card must not produce: framing can
   be refused by a response header or a browser policy, and the full-size link works regardless. */
test('V243 a preview that never paints says so instead of showing an empty frame', () => {
  const wire = section(app, 'function wireCustomerInterfacePreviewV243(', 'function customerInterfaceSectionsHtmlV243(');
  assert.match(preview, /<p class="muted small" id="customerAppPreviewBlockedV243"[^>]*hidden>/);
  assert.match(preview, /Use “Open full size” — your public page itself is unaffected\./);
  assert.match(wire, /painted=!!frame\.contentDocument\?\.getElementById\('root'\)/);
  assert.match(wire, /if\(blocked\)blocked\.hidden=painted;/);
});

test('V243 the preview points at the PUBLIC slug page, same-origin and relative', () => {
  const url = section(app, 'function customerInterfacePreviewUrlV243(', 'function customerInterfacePreviewCardHtmlV243(');
  // location.pathname keeps it same-origin on production, previews and the native WebView alike.
  assert.match(url, /return `\$\{location\.pathname\}#\/b\/\$\{encodeURIComponent\(String\(S\.biz\?\.slug\|\|''\)\)\}`;/);
  assert.doesNotMatch(url, /https?:\/\/|publicAppUrl/, 'no absolute host, and no tokened QR link');
  // A join token would be consumed by opening it; the slug page is safe to render repeatedly.
  assert.doesNotMatch(preview, /join\?token=/);
});

test('V243 the preview is honestly labelled and openable full size', () => {
  assert.match(preview, /<b>Preview the customer app<\/b>/);
  assert.match(preview, /This is your public page — what a customer sees before joining\. After joining, they also see your points, tiers and rewards in their wallet\./);
  assert.match(preview, /<a class="btn ghost sm" id="customerAppPreviewOpenV243" href="\$\{esc\(previewUrl\)\}" target="_blank" rel="noopener noreferrer">Open full size<\/a>/);
});

test('V243 the phone frame is a real device mock that still fits a 390px screen', () => {
  assert.match(preview, /<div class="customer-preview-phone-v243"><div class="customer-preview-screen-v243">/);
  assert.match(indexHtml, /\.customer-preview-phone-v243\{[^}]*width:390px;max-width:100%/);
  assert.match(indexHtml, /\.customer-preview-screen-v243\{[^}]*height:640px;max-height:70vh;[^}]*overflow:hidden/);
  assert.match(indexHtml, /\.customer-preview-screen-v243 iframe\{[^}]*width:100%;height:100%;border:0/);
  // The workspace page must never scroll sideways because of it.
  assert.match(indexHtml, /\.settings-page,\.settings-page \.split,\.settings-page \.card\{[^}]*min-width:0[^}]*max-width:100%/s);
  assert.match(page, /<div class="settings-page" data-workspace-i18n>/);
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
