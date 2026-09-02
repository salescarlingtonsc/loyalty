/* nestly_v584 — the owner's 2026-08-28 batch: seventeen marks over fifteen iPad screenshots.
 *
 * This file holds the items that have no older test to retarget. The ones that DO — the Bookings
 * settings tab (v195/v288/v291/v223/v235), the Products stock disclosure (v221), the per-service
 * commission card (v180), the staff roster columns (v226/v569), the Packages tabs (v157) and the
 * Referrals band (v154/v164/v229) — were rewritten in place, next to the ruling they overturn, so
 * the reason a behaviour changed stays with the assertion that used to require it.
 *
 * What is NOT asserted here: pixel positions. The four filter bars (photos 3, 4, 11 and 14) were
 * fixed structurally and measured in real Chrome before and after; what is pinned below is the
 * STRUCTURE that makes the measurement hold, because a rule that only happens to line up today is
 * the reason those four photos were drawn three times.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const shell = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');
const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start}`);
  return app.slice(from, to);
};

test('photo 1 — one workspace card fills the row instead of sitting in half of it', () => {
  /* "box misaligned, make it bigger", ringed round a single Business workspaces card that took
     the left half of a two-column grid and left the right half empty. */
  assert.match(shell, /\.entry-choice-grid\{display:grid;grid-template-columns:repeat\(auto-fit,minmax\(280px,1fr\)\)/);
  assert.match(shell, /\.entry-choice-card\{width:min\(860px,100%\)/);
  assert.doesNotMatch(shell, /\.entry-choice-grid\{display:grid;grid-template-columns:repeat\(2,/);
});

test('photos 3, 4, 11 and 14 — every filter bar puts labels and controls on their own rows', () => {
  /* The defect is not size, it is that the bars were BOTTOM-aligned rows of cells whose contents
     have different intrinsic heights, so a taller control pushed its own label up while its
     neighbour's stayed down — and the low label was drawn beside, or across, the tall box. Two
     rows per cell removes the variable; overflow:hidden means a control that insists on being
     wider than its cell is clipped inside it rather than painting over the next label. */
  assert.match(shell, /\.appointment-list-filters,\.v150-filterbar,\.wl-period-v571\{\s*\n\s*display:flex;flex-wrap:wrap;align-items:flex-start/);
  assert.match(shell, /\.appointment-list-filters>div,\.v150-filterbar>div,\.wl-period-v571>label\{\s*\n\s*display:grid;grid-template-rows:auto auto;row-gap:6px;align-content:start;margin:0;/);
  assert.match(shell, /overflow:hidden\}/);
  // The waitlist labels stopped carrying their own inline flex, which fought the shared rule.
  assert.doesNotMatch(app, /<label class="small" style="display:flex;flex-direction:column;gap:4px"><span>From<\/span>/);
});

test('photo 10 — the sales filters pack left and Clear sits with Apply', () => {
  const sales = section('const salesDefaultToV266=', 'const salesFilterNoteV266=');
  assert.match(sales, /<button class="btn sm" id="salesApply">Apply filters<\/button>\s*\n\s*<button class="btn ghost sm" id="salesClear">Clear filters<\/button>/);
  /* nestly_v658 (owner photo 6: "fix alignment, boxes are overlapping"). v584's compact bar was a
     grid whose column COUNT came from the 120px minimum, so at 1440px it laid out more tracks than
     the content needed and squeezed each toward that floor — while the controls inside keep fixed
     widths (a date box is 150px). Measured in Chrome: From/To overlapped by 6px and To/Customer
     search by 25px. A wrapping flex row sizes each cell by its own content, so a control can never
     be wider than the box it sits in and overlap is not expressible. What v584 was protecting —
     the bar packing LEFT rather than spreading — is what justify-content:flex-start keeps, and the
     assertion below still pins it. */
  assert.match(shell, /\.sales-filter-panel\{display:flex;flex-wrap:wrap;align-items:flex-end;justify-content:flex-start/);
  /* Narrowly the v584 rule, not any display:grid — the base rule at the top of the stylesheet
     still declares one and is overridden by the flex rule above, which is fine and is why the
     panel keeps its margin-bottom. */
  assert.doesNotMatch(shell, /\.sales-filter-panel\{display:grid;grid-template-columns:repeat\(auto-fit/,
    'the auto-fit track grid that caused the overlap is gone');
});

test('photos 2 and 8 — one pager, 20 rows a page, on both lists the owner drew it on', () => {
  assert.match(app, /const PAGE_SIZE_V584=20;/);
  assert.match(app, /pagerHtmlV584\(\{scope:'bookings',page:bookingRequestPageV584,total:br\.length,label:'Requests'\}\)/);
  assert.match(app, /pagerHtmlV584\(\{scope:'offers',page:growOffersPageV584,total:growOffersRowsV584\.length,label:'Offers'\}\)/);
  // Both page over rows that are already loaded, so a page change costs no round trip.
  assert.match(app, /const visibleV584=pageSliceV584\(br,bookingRequestPageV584\);/);
  assert.match(app, /pageSliceV584\(growOffersRowsV584,growOffersPageV584\)/);
  // A new bucket, and a new route, start at page one.
  assert.match(app, /growOffersTabV324=tab;\s*\n\s*growOffersPageV584=0;/);
  assert.match(app, /growOffersTabV324='published';growOffersPageV584=0;/);
});

test('photo 5 — Save is the last thing in the gift dialog, Delete the first', () => {
  const form = section('const growPointsAddFormV326=', '\n  /* V343 (owner mockup, photo 4): a dashed placeholder card');
  const del = form.indexOf('data-grow-points-gift-delete-v326=');
  const save = form.indexOf('data-grow-points-add-save-v326=');
  assert.ok(del > 0 && save > del, 'Delete on the left, Save at the end of the row');
  assert.match(form, /<span class="spacer"><\/span><button type="button" class="btn sm" data-grow-points-add-save-v326="1"/);
});

test('photo 6 — the referral panels are white cards, and the band is gone', () => {
  assert.match(app, /<div class="card grow-referral-panel-v584" data-grow-referral-summary-v375/);
  assert.match(app, /<div class="card grow-referral-panel-v584" data-grow-referral-settings-v364/);
  assert.match(shell, /\.grow-referral-panel-v584\{background:var\(--card,#fff\)/);
  assert.doesNotMatch(app, /programme-category-title">Referrals</);
});

test('photo 7 — Welcome gift has a landing page built like the birthday one', () => {
  const page = section('const growWelcomePageV584=', 'const growBbPageV361=');
  // Read off the same row the editor writes, so the page and the form cannot disagree.
  assert.match(app, /const growWelcomeV584=welcomeOfferStatusV215\?\.configured\?welcomeOfferStatusV215:null;/);
  for (const term of ['What they get', 'When they can use it', 'Expires', 'Terms']) {
    assert.ok(page.includes(`<dt>${term}</dt>`), `${term} is stated on the page`);
  }
  assert.match(page, /<span class="pill \$\{growWelcomeV584\.active\?'on':'off'\}"/);
  // It is a real view, with the same back control and title treatment the other pages have.
  assert.match(app, /'bringback','birthday','welcome','ongoing'/);
  assert.match(app, /programmeView==='welcome'\?growWelcomePageV584:''/);
  assert.match(app, /programmeView==='welcome'\?'Welcome gift'/);
});

test('photo 9 — nothing counts stock anywhere in the workspace', () => {
  for (const gone of [/id="badd2"/, /Count stock too/, /receive_stock/, /product_stock/, /opening_qty/]) {
    assert.doesNotMatch(app, gone);
  }
});

test('photo 12 — Customer packages is its own destination under Serve & sell', () => {
  assert.match(app, /custpackages:\['packages','Customer packages'\]/);
  assert.match(app, /items:\['till','appointments','bookings','waitlist','custpackages'\]/);
  assert.match(app, /custpackages:\(\)=>packagesPage\(\{view:'customers'\}\)/);
  assert.match(app, /packages:\(\)=>packagesPage\(\{view:'plans'\}\)/);
  /* It is a SURFACE, not an entitlement: the route guard resolves the alias and tests the real
     'packages' module, so a staff member without Packages cannot reach it by typing the hash. */
  /* nestly_v606 added a second surface (Reminder & Notification, gated on the Settings module).
     The pin now checks the ENTRY rather than the whole object, so a later surface does not have to
     rewrite an assertion about this one. */
  assert.match(app, /const SURFACE_MODULE_ALIAS_V584=Object\.freeze\(\{[^}]*custpackages:'packages'[^}]*\}\);/);
  assert.match(app, /const moduleGateKeyV584=SURFACE_MODULE_ALIAS_V584\[pageKey\]\|\|pageKey;/);
  assert.match(app, /&&!canReadModule\(moduleGateKeyV584\)\)\{/);
  // And a refresh from inside either view comes back to the view it was on.
  assert.match(app, /const refreshPackagesV584=\(\)=>\{if\(!isCurrent\(\)\)return;packagesPage\(\{view:packagesViewV584\}\)\};/); // audit F083/F085: a late write response never repaints a page the user left
  assert.doesNotMatch(app, /toast\('Package renamed'\);packagesPage\(\)/);
});

test('photo 13 — the booking decision is a tick and a cross with its words intact', () => {
  const bookings = section('async function bookingsPage(){', '\nasync function ');
  assert.match(bookings, /class="booking-decision booking-decision-yes-v584"[^>]*decideBookingRequestV73\('\$\{b\.id\}','confirm'\)/);
  assert.match(bookings, /class="booking-decision booking-decision-no-v584"[^>]*decideBookingRequestV73\('\$\{b\.id\}','decline'\)/);
  assert.match(bookings, /'confirmBookingFor'/);
  assert.match(bookings, /'declineBookingFor'/);
  // 40px round targets, not 20px glyphs.
  assert.match(shell, /\.booking-decision-yes-v584,\.booking-decision-no-v584\{[\s\S]{0,200}width:40px;height:40px/);
});

test('photo 14 — History shows one section at a time, and the paragraph is gone', () => {
  assert.match(app, /data-grow-history-tab-v584="rewards"/);
  assert.match(app, /data-grow-history-tab-v584="offers"/);
  assert.match(app, /scope:'HistoryV324'[^}]*tabbed:true/);
  // Overview keeps both columns side by side — the owner drew the tabs on History.
  assert.match(app, /const growOverviewTableV271=growOverviewFrameV324\(\{scope:'V319',rewards:growOverviewRewardsTableV319,offers:growOverviewOffersTableV319\}\);/);
  assert.doesNotMatch(app, /Showing the last month\./);
  assert.doesNotMatch(app, /Nothing is deleted\./);
});

test('photos 15 and 16 — the staff editor is a dialog with two tabs and a dustbin', () => {
  assert.match(app, /function staffEditDialogHtmlV584\(s\)\{/);
  assert.match(app, /data-staff-tab-v584="profile"/);
  assert.match(app, /data-staff-tab-v584="access"/);
  /* nestly_v595 made `hidden` conditional so the App access cell can open the dialog straight on
     this tab. What photo 16 asked for — the access actions and the module grid on ONE tab — is
     unchanged, and the default is still Profile. */
  assert.match(app, /<div data-staff-tabpanel-v584="access"\$\{openTabV595==='access'\?'':' hidden'\}>\$\{staffProfileActionsHtmlV577\(s\)\}\$\{modPanelHtml\(s\)\}<\/div>/);
  assert.match(app, /const openTabV595=showAccess&&staffEditTabV595==='access'\?'access':'profile'/);
  // Delete is the dustbin, with the same handler and the same confirm behind it.
  assert.match(app, /class="staff-delete-icon-v584"[^>]*onclick="rmStaff\('\$\{s\.id\}',this\)"/);
  const cui = readFileSync(new URL('../../app/customer-ui.js', import.meta.url), 'utf8');
  assert.match(cui, /trash:'M4 7h16/);
  // Save is the last control in the profile tab; Cancel is gone, the ✕ and the backdrop are not.
  assert.match(app, /<div class="row staff-profile-save-v584"[^>]*><span class="spacer"><\/span><button class="btn sm" onclick="saveStaffProfile/);
  assert.doesNotMatch(app, /onclick="toggleStaffProfile\('\$\{s\.id\}'\)">Cancel</);
  /* A save re-renders the roster while the dialog stays open, so the new activation inherits the
     old one's history entry rather than pushing a second — otherwise Back would need pressing
     once per save to leave one dialog. */
  assert.match(app, /previous\(\{restoreFocus:false,handOffHistory:!!staffDialogV584\}\);/);
  assert.match(app, /inheritHistoryId:CUI\.currentDialogHistoryId\?\.\(\)\|\|0,/);
});

test('photo 17 — a service is edited in one dialog, including its commission override', () => {
  const services = section('async function servicesPage(){', '/* ---------- bookings ---------- */');
  assert.match(services, /<div class="modal" id="svcEditModalV584" role="dialog" aria-modal="true"/);
  assert.match(services, /id="svcEditCommissionV584"/);
  assert.match(services, /<th class="num">Commission%/);
  // The "?" states what an override means, where the column is.
  assert.match(services, /helpDotMarkupV385\('the commission override'/);
  /* nestly_v658 (owner photo 7: the Packages row "will be the model that other modules follow
     (status / edit / delete) ... for products & services"). v584's separate ✓/✗ icon is gone: the
     STATUS PILL is the switch, as it already is on Packages, and switching OFF asks first. What
     v584 fixed — that the control is an icon/state rather than the words "Turn off" — still holds,
     and the doesNotMatch below still pins it. */
  assert.match(services, /<button type="button" class="pill \$\{s\.active\?'on':'off'\}" data-svc-active="\$\{s\.id\}"/);
  assert.doesNotMatch(services, /svc-toggle-icon-v584[^"]*"[^>]*onclick="toggleSvc/, 'the separate toggle icon is gone');
  assert.doesNotMatch(services, />\$\{s\.active\?'Turn off':'Turn on'\}</);
  // Blank still means "not decided", which is a different setting from 0%.
  assert.match(services, /commissionRawV584===''\?null:Math\.round\(parseFloat\(commissionRawV584\)\*100\)/);
});
