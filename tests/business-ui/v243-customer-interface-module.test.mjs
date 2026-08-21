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
   100%"). Bio is still listened for (harmless — it just re-triggers an identical render) but not
   READ here: the wallet a customer reaches after joining never shows it (confirmed against
   renderCustomerWallet/customerMerchantExperienceMarkupV95 — bio is not referenced anywhere in
   that render path). Only the pre-join public portal shows it, which this preview no longer
   represents.
   V334 (owner markup, photo 10: "why this not reflected?"): booking policy is the one exception —
   it IS shown to real customers elsewhere (booking confirmation, appointment detail rows), so the
   owner's ask to see it preview here is honoured by reading it directly, as its own note beneath
   the wallet render rather than by widening customerMerchantExperienceMarkupV95's signature. */
test('V327 the preview calls the REAL wallet render function, not a hand-rolled lookalike', () => {
  const markup = section(app, 'function customerInterfaceLivePreviewMarkupV326(', 'function customerInterfacePreviewSideCardHtmlV325(');
  assert.match(markup, /customerMerchantExperienceMarkupV95\(\{/);
  assert.match(markup, /customerPrimaryNavigation\('programmes',\{\}\)/);
  assert.doesNotMatch(markup, /\$\('bbio'\)/, 'bio never renders in the wallet — reading it here would show a field production never displays');
  assert.match(markup, /\$\('bp'\)\?\.value\|\|S\.biz\.booking_policy/, 'booking policy IS previewed now, read live like name/brandColor above');
  // The sample numbers are clearly labelled, not presented as if they were a real customer's.
  /* nestly_v417 (owner, photo 11: the preview ringed — "sync to live reward programmes"). Which
     programmes appear, and whether they count points or stamps, come off the spine now; only the
     CUSTOMER is still invented, because a preview has nobody in it. The badge says which half is
     which rather than disclaiming the whole thing. */
  assert.match(markup, /Your live programme setup, shown with a sample customer/);
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
  assert.match(preview, /This is the wallet a customer reaches by clicking into your firm — their tier, points and rewards\. Your bio and booking policy show on your public page instead, before a customer joins\./);
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
