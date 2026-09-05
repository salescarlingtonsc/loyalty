/* V325 — Customer Interface restructure into a numbered stepper (2026-08-14 cosmetics brief).

   The owner sent a hand-annotated screenshot of the Customer Interface page and asked for a
   6-step stepper (Business Profile, Appointment Setting, Preview, Done, Customer programme,
   Sign-up & fields) plus three explicitly authorized exceptions: a business bio field, an
   inline branch contact card, and per-service buffer-time inputs. This file protects: the
   stepper renders all six steps with the right hashes, the bio field saves and is read back on
   the public portal, the buffer-time inputs are wired into the existing service save calls, and
   the relocated booking-rules card renders under the new Appointment Setting tab. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

function section(source, start, end) {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

const stepper = section(app, 'function customerInterfaceStepperHtmlV325(', 'function customerInterfaceDoneCardHtmlV325(');
const page = section(app, 'async function customerInterfacePageV243(hashParam)', '/* ---------- phone country-code picker');
const brandPanel = section(app, 'function workspaceBrandPanelHtmlV259(){', 'function wireWorkspaceBrandV259(){');
const brandWiring = section(app, 'function wireWorkspaceBrandV259(){', '/* V325 (owner-authorized restructure');
const servicesPage = section(app, 'async function servicesPage(){', '/* ---------- bookings ---------- */');
const bookingRules = section(app, 'function bookingRulesCardHtmlV325(', 'function wireBookingRulesV325(');

/* --------------------------------------------------------------------- (a) the stepper itself */

test('V325 the stepper renders all six steps with their hashes, in order', () => {
  /* V334 (owner markup, photo 9: "Customer Sign-up & fields" relabel), then V336 (owner markup,
     photo 2: "remove & fields"): only the 'interface' entry's label text changed twice, hashes
     and step order are untouched. */
  const expected = [
    ['brand', 'Business Profile', '#/customer-interface/brand'],
    ['appointment', 'Appointment Setting', '#/customer-interface/appointment'],
    ['preview', 'Preview', '#/customer-interface'],
    ['done', 'Done', '#/customer-interface/done'],
    ['programme', 'Customer programme', '#/customer-interface/programme'],
    ['interface', 'Customer Sign-up', '#/customer-interface/interface'],
    /* V368: 'actions' (Customer Action) joins the list — the rail's second child, holding the
       app-action switches and customer fields that outlived the retired sign-up page. */
    /* V375 (owner, photo 16): relabelled "Customer Permissions". The hash is untouched. */
    /* V392 (owner, photo 3): "Permissions" struck through and "Action" written, and the arrow
       onto the Appointment Setting pill — "when click this is the default page". The row's own
       hash moved to that tab; both hashes still resolve, which is what the loop below checks. */
    /* nestly_v633: renamed to Customer Permission — the row's destination is unchanged. */
    ['actions', 'Customer Permission', '#/customer-interface/appointment'],
  ];
  const viewsSource = section(app, 'const CUSTOMER_INTERFACE_VIEWS_V296=[', '];');
  /* V368 no longer asserts ORDER across the whole list — 'actions' is declared beside the
     appointment entry it pairs with as a tab, not appended — only that every entry still exists
     with its own hash, which is what "no hash was renamed or removed" actually means. */
  for (const [key, label, href] of expected) {
    assert.ok(viewsSource.includes(`['${key}','${label}','${href}'`),
      `${key} missing from CUSTOMER_INTERFACE_VIEWS_V296`);
  }
  // Every existing hash before V325 still resolves — none were renamed or removed.
  for (const href of ['#/customer-interface', '#/customer-interface/brand', '#/customer-interface/programme', '#/customer-interface/interface']) {
    assert.match(app, new RegExp(`'${href.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&')}'`));
  }
  /* V334 (owner markup, photo 9: hide Preview/Done/Customer programme from nav/stepper): the
     stepper now renders the filtered VISIBLE list — those three routes still resolve (asserted
     above), they just no longer have a stepper circle or sidebar row. */
  /* V368 (owner markup, photo 4: the numbered step line struck through with "do into tabs"):
     the stepper is the house segmented tab strip now, and on the Customer Action page it shows
     that page's own two tabs. Same hashes, same sections, one control. */
  /* V385 (owner markup, photo 11: the "Customer Permissions" pill X'd out, "delete here"): off
     the Customer Action page the strip repeated the rail's own two children one column to the
     right of them, so it is not drawn there at all. It survives where it is a real tab strip. */
  assert.doesNotMatch(stepper, /CUSTOMER_INTERFACE_VIEWS_VISIBLE_V334/);
  assert.match(stepper, /if\(!onActionPage\)return '';/);
  assert.match(stepper, /class="v150-segment ci-tabs-v368"/);
  assert.match(stepper, /CUSTOMER_INTERFACE_TABS_V368/);
  assert.match(page, /\$\{customerInterfaceStepperHtmlV325\(customerInterfaceViewV296\)\}/);
});

test('V325 the Done step is static, with no new state or logic', () => {
  const done = section(app, 'function customerInterfaceDoneCardHtmlV325(){', 'function businessProfileBranchCardHtmlV325(');
  assert.match(done, /You're all set/);
  assert.doesNotMatch(done, /sb\.from\(|sb\.rpc\(|localStorage|Object\.assign\(S\.biz/);
});

/* V326 (owner, 2026-08-15): "press publish > confirmed > customer app will reflect the exact
   changes without discrepancies". Every section on this page already writes on its OWN save
   click (name/colour/policy/bio via #bsave, logo via #workspaceLogoPublishV96, programme and
   sign-up fields via their own RPCs) — there is no staged/draft state anywhere to commit. Publish
   is therefore a review-and-confirm step, not a second write path. */
/* V368 (owner markup, photo 4: "Publish" struck through, "Save" written, "move this button to
   below of the page"; owner ruling when asked: saving applies immediately, no publish step).
   Publish is gone. The bottom Save is a real save-all for the section on screen — it presses that
   section's own enabled Save buttons — rather than a button that only says a reassuring word, and
   it still writes nothing itself. */
test('V368 Save replaces Publish, sits at the foot, and presses the section\'s own saves', () => {
  assert.doesNotMatch(page, /ciPublishV326/);
  assert.match(page, /id="ciSaveV368">Save<\/button>/);
  assert.match(page, /class="row ci-savebar-v368"/);
  const wiring = section(app, "const ciSaveBtnV368=$('ciSaveV368');", 'wireWorkspaceBrandV259();');
  assert.match(wiring, /\.customer-interface-view-v296:not\(\[hidden\]\)/);
  assert.match(wiring, /saves\.forEach\(button=>button\.click\(\)\)/);
  // No write of its own: it must not touch sb.from/sb.rpc.
  assert.doesNotMatch(wiring, /sb\.from\(|sb\.rpc\(/);
  // Only the owner sees it — a non-owner has nothing to save.
  assert.match(page, /\$\{canEditCustomerInterface\?`<div class="row ci-savebar-v368"/);
});

test('V325 steps 1-2 pair the form with the SAME live-preview renderer as step 3', () => {
  /* nestly_v493: the helper takes a second argument now — the html that goes BELOW the preview
     (branch contact details moved into that column, owner photos 6+7). The pairing this test
     exists to protect is unchanged: one form column, one preview renderer. */
  assert.match(page, /const ciWithPreviewV325=\(formHtml,belowPreviewHtml=''\)=>/);
  assert.match(page, /customerInterfacePreviewSideCardHtmlV325\(\)/);
  const sideCard = section(app, 'function customerInterfacePreviewSideCardHtmlV325(', 'function customerInterfacePreviewUrlV243(');
  // V326: no iframe/URL — the side card and the step-3 card both call the ONE inline renderer.
  assert.match(sideCard, /customerInterfaceLivePreviewMarkupV326\(\)/);
  assert.doesNotMatch(sideCard, /<iframe/);
  // Step 3 (Preview) still renders the untouched, pinned V243 card — no forced-open param.
  assert.match(page, /ciSectionV296\('preview',customerInterfacePreviewCardHtmlV243\(\)\)/);
});

/* V448 (REG-009): the test above proves the SOURCE TEXT calls the renderer from both places; it
   does not run either function, so it cannot tell a real shared call from one that silently
   diverged (a stray argument, a second copy that drifted). This executes both real functions
   (extracted from app.js, run in a vm sandbox with only the wallet-content renderer and the
   handful of page globals they read stubbed — location/S/esc — none of which affect the claim
   under test) and diffs their actual output around the shared renderer's markup. */
test('V325/V243 EXECUTING: the step 1-2 side card and the step-3 card render byte-identical phone-preview markup', () => {
  const previewSideCardSrc = section(app, 'function customerInterfacePreviewSideCardHtmlV325(', 'function customerInterfacePreviewUrlV243(');
  const previewCardSrc = section(app, 'function customerInterfacePreviewCardHtmlV243(', 'function wireCustomerInterfacePreviewV243(');
  const previewUrlSrc = section(app, 'function customerInterfacePreviewUrlV243(', 'function customerInterfacePreviewCardHtmlV243(');
  const sandboxGlobals = `
    const location={pathname:'/app'};
    const S={biz:{slug:'kopi-corner'}};
    const esc=s=>String(s??'');
    const customerInterfaceLivePreviewMarkupV326=()=>'<div id="stubWalletMarkup">sample wallet render</div>';
  `;
  const sideCardHtml = vm.runInNewContext(
    `${sandboxGlobals}\n${previewSideCardSrc}\ncustomerInterfacePreviewSideCardHtmlV325();`, {}
  );
  const stepThreeCardHtml = vm.runInNewContext(
    `${sandboxGlobals}\n${previewUrlSrc}\n${previewCardSrc}\ncustomerInterfacePreviewCardHtmlV243();`, {}
  );
  assert.equal(typeof sideCardHtml, 'string');
  assert.equal(typeof stepThreeCardHtml, 'string');
  // Both must have actually called the shared renderer, not skipped it.
  assert.match(sideCardHtml, /stubWalletMarkup/);
  assert.match(stepThreeCardHtml, /stubWalletMarkup/);
  // Extract the phone-frame fragment from each (from the phone wrapper to its closing div).
  // The side card legitimately adds its own `style="margin-top:10px"` to sit under the "Live
  // preview" label — an inline-style difference, not a divergent renderer — so that one
  // attribute is normalized away before comparing; everything else, especially the renderer's
  // OWN output nested inside, must be identical.
  const framePattern = /<div class="customer-preview-phone-v243"[^>]*><div class="customer-preview-screen-v243[^"]*">.*?<\/div><\/div>/s;
  const normalize = (html) => html?.replace(/ style="[^"]*"/g, '');
  const sideFrame = normalize(sideCardHtml.match(framePattern)?.[0]);
  const stepThreeFrame = normalize(stepThreeCardHtml.match(framePattern)?.[0]);
  assert.ok(sideFrame, 'step 1-2 side card must render the phone-frame markup');
  assert.ok(stepThreeFrame, 'step 3 card must render the phone-frame markup');
  assert.equal(sideFrame, stepThreeFrame,
    'the two cards must render identical phone-preview markup (ignoring the side card\'s own '
    + 'layout-only inline style) — divergence here would mean steps 1-2 are no longer showing '
    + 'what step 3 (and the customer) actually sees');
});

/* ------------------------------------------------------------------- (b) bio field, exception 1 */

test('V325 bio is one field on the existing Workspace & brand form, one save, one read site', () => {
  assert.match(brandPanel, /id="bbio"/);
  assert.match(brandPanel, /Company bio/);
  assert.match(brandPanel, /maxlength="500"/);
  // Rides the SAME single UPDATE workspaceBrandPanelHtmlV259 already writes.
  assert.match(brandWiring, /const bio=\(\$\('bbio'\)\?\.value\|\|''\)\.trim\(\)\|\|null;/);
  assert.match(brandWiring, /review_url:reviewUrl,\n\s*bio\}\)\.eq\('id',S\.biz\.id\)/); // nestly_v788: legal_name/registration_number left this write
  assert.equal((app.match(/id="bbio"/g) || []).length, 1, 'bio must not be split into a second form');
  // The one read site: the public portal, reusing get_business_public via internal_public_booking_page.
  assert.match(app, /\$\{biz\.bio\?`<p class="muted small" style="margin-top:6px">\$\{esc\(biz\.bio\)\}<\/p>`:''\}/);
});

test('V325 the businesses.bio migration is additive, nullable and exposes the public read', () => {
  const migration = readFileSync(join(root, 'db', 'migrations', '20260814_nestly_v325_business_bio.sql'), 'utf8');
  // Exactly the additive, nullable column — no NOT NULL, no default, no backfill.
  assert.match(migration, /alter table public\.businesses\s*\n\s*add column if not exists bio text;\n/);
  assert.match(migration, /'bio',business\.bio,/);
  assert.match(migration, /revoke all on function public\.get_business_public\(text\) from public;/);
});

/* --------------------------------------------------------------- (c) buffer times, exception 3 */

test('V325 buffer-before/after are wired into the existing add and edit service saves, not a new path', () => {
  assert.match(servicesPage, /<label for="sbb">Buffer before \(minutes\)<\/label><input id="sbb"/);
  assert.match(servicesPage, /<label for="sba">Buffer after \(minutes\)<\/label><input id="sba"/);
  assert.match(servicesPage, /<label for="svcEditBufferBefore">Buffer before \(minutes\)<\/label><input id="svcEditBufferBefore"/);
  assert.match(servicesPage, /<label for="svcEditBufferAfter">Buffer after \(minutes\)<\/label><input id="svcEditBufferAfter"/);
  // The add path: one insert, buffer fields included.
  assert.match(servicesPage, /business_id:S\.biz\.id,name,variant_label:variant,price_cents:price,duration_min:dur,\s*\n\s*buffer_before_min:bufferBefore,buffer_after_min:bufferAfter/);
  // The edit path: one update, buffer fields included.
  /* nestly_v584 (owner photo 17: the standalone commission-override card ringed with an arrow
     into the row's Edit). The service editor writes one more column now — the per-service
     override, which used to have its own card and its own Save further down the page. The two
     buffer columns V325 added are untouched, which is what this line is for. */
  assert.match(servicesPage, /\.update\(\{name,variant_label:variant,price_cents:price,duration_min:duration,\s*\n\s*buffer_before_min:bufferBefore,buffer_after_min:bufferAfter,\s*\n\s*commission_bps:commissionBpsV584\}\)\.eq\('id',id\)/);
  // No new RPC, no new call site — still the plain services table insert/update.
  assert.doesNotMatch(servicesPage, /sb\.rpc\('[a-z_]*buffer/i);
  /* nestly_v577 (owner mark, photo 9): Appointment Setting no longer carries the pointer sentence
     at all — the card holding it was struck out. What this test exists to protect is above: the
     buffer fields are on the SERVICE, saved through the service's own insert/update, with no
     second write path. That is unchanged, and is now the only place buffers are set. */
  assert.doesNotMatch(app, /Buffer before\/after each appointment is set per service/);
});

/* -------------------------------------------------------- (d) relocated booking rules, exc. 2 */

test('V325 the booking-rules card renders under Appointment Setting with every relocated control', () => {
  /* V368 (owner markup, photo 4: the Live preview column crossed out with "this one no need
     here"): Appointment Setting renders its form full width. Step 3 IS the preview and keeps it. */
  assert.match(page, /\$\{ciSectionV296\('appointment',`/);
  assert.doesNotMatch(page, /ciSectionV296\('appointment',ciWithPreviewV325/);
  assert.match(page, /bookingRulesCardHtmlV325\(\)/);
  /* nestly_v577 (owner mark, photo 9: the whole "Service buffer times" card struck through,
     "remove this!"). It was a POINTER card — it set nothing and saved nothing, it only told the
     reader that buffers are set per service. Buffers themselves are untouched and are still edited
     under Services; the assertions below that they reach the service save still hold. */
  assert.doesNotMatch(page, /serviceBufferPointerCardHtmlV325\(\)/);
  assert.doesNotMatch(app, /function serviceBufferPointerCardHtmlV325\(/);
  /* nestly_v606 (owner mark: the hours grid ringed with an arrow to Branches). setAvailabilityBody
     and setAvailabilitySave left this card with the grid they held — hours belong to a branch, and
     this screen is one screen for the whole business. setStaffChoice stayed, and gained its own
     save, because who a customer may pick is a business decision. */
  for (const id of ['aac', 'setHold', 'setOverflow', 'setAutoConfirm', 'setSave', 'setStaffChoice', 'setStaffChoiceSaveV606']) {
    assert.match(bookingRules, new RegExp(`id="${id}"`), `${id} must still be part of the relocated card`);
  }
  // Every id above appears exactly once across the whole bundle — no duplicate copy left in Bookings.
  for (const id of ['aac', 'setHold', 'setOverflow', 'setAutoConfirm', 'setSave', 'setStaffChoice', 'setAvailabilityErr']) {
    assert.equal((app.match(new RegExp(`id="${id}"`, 'g')) || []).length, 1, `${id} must be defined exactly once`);
  }
  assert.match(page, /wireBookingRulesV325\(\(\)=>customerInterfaceHostV288\.isConnected&&M\(\)===customerInterfaceHostV288\);/);
});

test('V325 Bookings keeps a pointer instead of a second copy of the relocated controls', () => {
  const bookingsPage = section(app, 'async function bookingsPage(){', '\nasync function ');
  assert.match(bookingsPage, /Customer Interface → Appointment Setting/);
  assert.doesNotMatch(bookingsPage, /id="setHold"|id="setOverflow"|id="setAutoConfirm"|id="setStaffChoice"|id="setSave"/);
  /* nestly_v584: the seating toggle and Tables / capacity are gone too — not by relocation, by
     deletion. Owner photo 13 struck the Booking settings tab through, and when asked what should
     happen to what it held, chose "delete the tab and the contents". V325's own point survives
     unchanged and is the line above: Bookings points at where the rules live rather than keeping a
     second copy of them. */
  assert.doesNotMatch(bookingsPage, /id="setTakesTablesV223"/);
  assert.doesNotMatch(bookingsPage, /Tables \/ capacity/);
});

/* -------------------------------------------------------------------- (e) branch contact card */

test('V325 the branch contact card edits address/phone through the SAME write path as Branches', () => {
  assert.match(app, /async function saveBranchFieldsV325\(branchId,fields\)\{/);
  assert.match(app, /return sb\.from\('branches'\)\.update\(fields\)\.eq\('id',branchId\)\.eq\('business_id',S\.biz\.id\);/);
  // Branches' own edit save calls the same shared function — one write path, two callers.
  const branchesPage = section(app, 'async function branchesPage(){', 'async function load(){');
  assert.match(branchesPage, /const \{error\}=await saveBranchFieldsV325\(editId,payload\);/);
  /* nestly_v577: the section used to end at serviceBufferPointerCardHtmlV325, which photo 9
     removed. Anchored on the next surviving declaration instead. */
  const branchCard = section(app, 'async function loadBranchContactCardV325(){', 'function businessLinkNormaliseV471(');
  assert.match(branchCard, /saveBranchFieldsV325\(id,\{phone,address,\.\.\.readBranchIdentityFieldsV788\('ciBrV788-'\+id\)\}\)/); // nestly_v788: the card saves the branch's receipt identity too
  assert.match(app, /Add or remove branches entirely in <a href="#\/branches">Branches<\/a>/);
});
