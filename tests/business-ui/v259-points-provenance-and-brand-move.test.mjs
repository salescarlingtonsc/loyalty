/* V259 — two owner reports against the Peekaa business portal.

   (1) "points not fixed yet - does not sync with actual points and not clickable to see where the
       points came from". The earn engine is correct and the two surfaces agree: the Customer 360
       card reads staff_get_customer_actionable_loyalty_v145.points_balance and the customer wallet
       reads customer_get_wallet — BOTH report 0 while the programme is paused, by design, while
       points_ledger still holds every point ever earned. What was missing was any explanation, and
       any way to see the rows. This file pins the explanation and the provenance dialog.

   (2) The owner drew arrows from all three Settings tabs onto the Customer Interface nav item.
       V243 moved two and deliberately left Workspace & brand behind because it is ONE interleaved
       form behind a single #bsave write. V259 moves it WHOLE. The contract is that it moved, not
       that it was copied: one definition of the markup, one save handler, a pointer in Settings. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

const clientDetail = section('async function clientDetail(id){', 'function renderHistPage(history,n){');
const settings = section('async function settingsPage(){', '/* ---------- billing (read-only) ---------- */');
const brandPanel = section('function workspaceBrandPanelHtmlV259(){', 'function wireWorkspaceBrandV259(){');
const brandWiring = section('function wireWorkspaceBrandV259(){', '/* The public page a customer meets before joining.');
const interfacePage = section('async function customerInterfacePageV243(hashParam)', '/* ---------- phone country-code picker');

/* ------------------------------------------------------- (1a) the number is a real control */

test('V259 the POINTS number is a button that opens a dialog, not inert text', () => {
  assert.match(clientDetail, /<button type="button" id="c360PointsHistoryV259"[^>]*aria-haspopup="dialog"/);
  assert.match(clientDetail, /aria-label="View points history"/);
  assert.match(clientDetail, /\$\('c360PointsHistoryV259'\)\.onclick=\(\)=>openPointsHistoryV259\(\)/);
  // the value it renders is still the ONE balance the KPI always showed — no second source
  assert.match(clientDetail, /id="c360PointsHistoryV259"[^>]*>\$\{pts\}<\/button>/);
});

test('V259 the dialog uses the shared modal + CUI.activateDialog pattern', () => {
  assert.match(clientDetail, /<div class="modal" id="c360PointsHistoryDialogV259" role="dialog" aria-modal="true"/);
  assert.match(clientDetail, /<div class="modal-card"/);
  assert.match(clientDetail, /CUI\.activateDialog\(dialog,\{onClose:close,initialFocus:'#c360PointsHistoryCloseV259'\}\)/);
  // opened from the page, so it owns its own history entry outright
  assert.match(clientDetail, /handOffHistory \/ inheritHistoryId hand-off/);
});

/* ------------------------------------------------------- (1b) the rows are the real ledger */

test('V259 the history reads points_ledger, business- and customer-scoped, oldest first', () => {
  assert.match(clientDetail, /sb\.from\('points_ledger'\)\s*\n?\s*\.select\('id,created_at,entry_type,points,sale_id,reference'/);
  assert.match(clientDetail, /\.eq\('business_id',S\.biz\.id\)\.eq\('client_id',id\)/);
  assert.match(clientDetail, /\.order\('created_at',\{ascending:true\}\)\.order\('id'\)/);
});

test('V259 every row names what happened, where it came from and a signed amount', () => {
  assert.match(clientDetail, /type==='earn'\?'Earned from a sale'/);
  assert.match(clientDetail, /:type==='redeem'\?'Redeemed for a reward'/);
  assert.match(clientDetail, /:type==='expire'\?'Points expired'/);
  assert.match(clientDetail, /:type==='adjust'\?'Manual adjustment'/);
  // the signed amount, and a source that is never invented
  assert.match(clientDetail, /\$\{amount>0\?'\+':''\}\$\{amount\}/);
  assert.match(clientDetail, /entry\.sale_id\?'Sale · not visible to this role'/);
  assert.match(clientDetail, /'No source recorded'/);
});

test('V259 the dialog carries a running balance, newest first', () => {
  assert.match(clientDetail, /running\+=Number\(entry\.points\)\|\|0;return \{entry,balance:running\}/);
  assert.match(clientDetail, /withBalance\.slice\(\)\.reverse\(\)\.map\(row=>pointsHistoryRowHtmlV259\(row\.entry,row\.balance\)\)/);
  assert.match(clientDetail, /<th>When<\/th><th>What happened<\/th><th>Source<\/th>/);
  /* The numeric columns moved off inline styles onto the shared .num helper, which also
     brings tabular figures so the balances line up digit for digit. */
  assert.match(clientDetail, /<th class="num">Balance<\/th>/);
});

test('V259 an unreadable or empty ledger is explained, never rendered as a silent zero', () => {
  assert.match(clientDetail, /title:'Points history unavailable'/);
  assert.match(clientDetail, /title:'No points movements yet'/);
  assert.doesNotMatch(clientDetail, /pointsHistoryResultV259=\{rows:\[\]\};\s*return/);
});

/* --------------------------------------------------------- (1c) a paused programme SAYS SO */

test('V259 the paused line renders only when the programme is not live', () => {
  assert.match(clientDetail, /const programmePausedV259=loyaltyFactsAvailable&&!!prog&&prog\.active!==true;/);
  assert.match(clientDetail, /const pointsPausedNoteV259=programmePausedV259\s*\n?\s*\?/);
  assert.match(clientDetail, /Programme paused — sales are not earning points right now\./);
  // the empty string is the other branch: an active programme prints nothing at all
  assert.match(clientDetail, /Points already earned stay in the history\.<\/p>'\s*\n?\s*:'';/);
  assert.equal((app.match(/Programme paused — sales are not earning points right now\./g) || []).length, 1,
    'one sentence, one definition — the card and the dialog render the same string');
  assert.match(clientDetail, /\$\{pointsPausedNoteV259\}\$\{pointsExpiryMarkup\}/);
});

test('V259 a paused programme is still distinguished from one that was never built', () => {
  /* V296 retarget (owner struck the paused PARAGRAPH out on 2026-08-12), NOT a weakening. V259's
     requirement is that "paused" and "never set up" are told apart. They still are, and now by the
     programme row itself: a paused programme renders a row with a Paused pill and this customer's
     own balance, while a business with no programme at all renders no row and keeps the explicit
     "Rewards are not set up yet" sentence. The paragraph the pill already said is gone. */
  assert.doesNotMatch(clientDetail, /This programme is paused, so nothing can be redeemed right now\./);
  assert.match(clientDetail, /Rewards are not set up yet\. The owner can create them from Grow\./);
  /* V319 added two optional trailing parameters (copyHtml for the clickable balance, footHtml for
     the paused note that now travels with the number it explains). The four this test names are
     unchanged and still positional. */
  assert.match(clientDetail, /programmeRowHtmlV294=\(name,copy,live,label=null,copyHtml=null,footHtml=''\)/);
  /* And the paused note reaches the row, so "paused" is still told apart from "never built" at
     the place the 0 is now printed. */
  assert.match(clientDetail, /balanceLeadHtmlV319\([^)]*\),pointsPausedNoteV259\)/);
  assert.match(clientDetail, /<span class="pill \$\{live\?'on':'off'\}">\$\{esc\(label\|\|statusOnOff\(live\)\)\}<\/span>/);
});

test('V259 the dialog explains the 0 on the card instead of contradicting it', () => {
  assert.match(clientDetail, /The card behind this dialog shows 0 because the programme is paused — these points were not removed\./);
});

/* ---------------------------------------- (2) Workspace & brand moved, whole and only once */

test('V259 the Workspace & brand form lives in the Customer Interface module', () => {
  // V269 wrapped the three panels in named sections; the owner gate is now the one ternary
  // around all three, so the panel call itself is no longer individually guarded.
  assert.match(interfacePage, /\$\{workspaceBrandPanelHtmlV259\(\)\}/);
  assert.match(interfacePage, /wireWorkspaceBrandV259\(\);/);
  // brand/identity first, then the customer programme, then sign-up QR and app actions
  const order = ['workspaceBrandPanelHtmlV259()', 'customerProgrammeEditorV95', 'customerInterfaceSectionsHtmlV243('];
  let cursor = -1;
  for (const marker of order) {
    const at = interfacePage.indexOf(marker);
    assert.ok(at > cursor, `${marker} is out of order inside the module`);
    cursor = at;
  }
});

test('V259 the form travelled WHOLE — one form, one save, no fork', () => {
  assert.equal((app.match(/id="bsave"/g) || []).length, 1, 'exactly one Workspace & brand form');
  assert.equal((app.match(/\$\('bsave'\)\.onclick=/g) || []).length, 1, 'exactly one #bsave handler');
  assert.equal((app.match(/function workspaceBrandPanelHtmlV259\(\)\{/g) || []).length, 1);
  assert.equal((app.match(/function wireWorkspaceBrandV259\(\)\{/g) || []).length, 1);
  // every field the single UPDATE writes is still in the one panel
  /* V325 (owner-authorized exception #1, 2026-08-14 Customer Interface cosmetics brief): 'bbio'
     joined this same interleaved form and the same single UPDATE — still one form, one save. */
  /* V375 (owner, photo 17): 'bc', the brand colour picker, was removed from the form. */
  /* V385 (owner, photo 12): 'bp', the booking policy, moved to Appointment Setting and left this
     write with it — so the rule this test guards is unchanged and still exact. Every field the
     one UPDATE writes is in the one panel, and the panel holds no field the UPDATE ignores.
     'bilabel' joined both at once (owner, photo 11). */
  for (const id of ['bn', 'bi', 'bilabel', 'bbio', 'blegal', 'buen', 'bru']) {
    assert.match(brandPanel, new RegExp(`id="${id}"`), `${id} must not be split out of the form`);
  }
  assert.doesNotMatch(brandPanel, /id="bp"/, 'the booking policy is saved by Appointment Setting now');
  /* Scoped to the #bsave UPDATE itself — `brandWiring` runs on past this handler and into the
     Appointment Setting card, which is exactly where booking_policy is supposed to be written now. */
  const bsaveUpdate = brandWiring.slice(brandWiring.indexOf("sb.from('businesses').update("),
    brandWiring.indexOf("Object.assign(S.biz"));
  assert.doesNotMatch(bsaveUpdate, /booking_policy/, 'this save must not blank a column it no longer shows');
  assert.match(brandWiring, /sb\.from\('businesses'\)\.update\(\{name:\$\('bn'\)\.value\.trim\(\),/);
  assert.match(brandWiring, /industry,industry_label:industryLabel,review_url:reviewUrl,/);
  assert.match(brandWiring, /legal_name:legalName,registration_number:registrationNumber,bio\}\)\.eq\('id',S\.biz\.id\)/);
});

/* V269 SUPERSEDES the pointer half of this test: the owner read the pointer card and told us to
   delete it along with the tab. What still matters — and is what this test was really guarding —
   is that Settings never grows a second copy of the form. */
test('V269 Settings carries neither the tab nor a second copy of the form', () => {
  assert.doesNotMatch(settings, /data-settab="workspace"/);
  assert.doesNotMatch(settings, /settingsMovedToCustomerInterfaceCardV243/);
  assert.doesNotMatch(settings, /id="bsave"|id="bru"|<label for="bc">/);
  // the loader moved with its host; only the explanatory comment still names it here
  assert.doesNotMatch(settings, /^\s*loadWorkspaceLogoEditorV96\(\);/m);
});

test('V259 the owner-only gate is unchanged on both sides of the move', () => {
  // both routes fail closed for a typed hash, identically
  assert.match(app, /if\(pageKey==='settings'&&S\.myRole!=='owner'\)\{/);
  assert.match(app, /if\(pageKey==='customer-interface'&&S\.myRole!=='owner'\)\{/);
  assert.match(interfacePage, /const canEditCustomerInterface=S\.myRole==='owner';/);
  assert.match(brandWiring, /if\(S\.myRole==='owner'\)loadWorkspaceLogoEditorV96\(\);/);
});
