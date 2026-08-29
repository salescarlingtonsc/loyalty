/* nestly_v417 — the owner's sixth annotated batch, ten screens.

   Two of the marks REVERSE stated rules, and both are recorded here rather than quietly dropped:
     * photos 1/3/4 reverse "Your photo is always shown whole — never cropped or covered". Cards
       crop to one shape now so two offers look the same size; opening an offer still shows the
       photo whole. (Asserted in v173/v192, which owned that rule.)
     * photo 9 removes the Messages gear. The settings it hid are NOT removed with it — that
       would take a real choice away from customers under cover of a cosmetic tidy.

   Photo 12 is the stamp card and shipped separately as nestly_v416. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const html = readFileSync(join(root, 'app', 'index.html'), 'utf8');
const migration = readFileSync(
  join(root, 'db', 'migrations', '20260821_nestly_v417_customer_bio.sql'), 'utf8');

const statement = (start, end, source = appJs) => {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing statement ${start} … ${end}`);
  return source.slice(from, to + end.length);
};
const esc = v => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const ruleFor = selector => {
  const at = html.indexOf(selector + '{');
  assert.ok(at >= 0, `missing rule ${selector}`);
  return html.slice(at, html.indexOf('}', at));
};

/* ------------------------------------------------ photo 5: the tab that went nowhere --------- */

test('v417 each Customer Action tab has its own destination', () => {
  /* It "cannot click" because both tabs carried #/customer-interface/appointment: V392 pointed the
     RAIL row there, and the strip read its href from the same tuple. */
  const strip = statement('function customerInterfaceStepperHtmlV325(', '\n}');
  assert.match(strip, /href="#\/customer-interface\/\$\{esc\(key\)\}"/,
    'a tab goes to its own view, not to wherever the rail row points');
  assert.doesNotMatch(strip, /\[key,label,href\]/, 'the rail landing href is no longer read here');
  /* v392's ruling is untouched: the rail row still lands on Appointment Setting. */
  assert.match(appJs, /\['actions','Customer Action','#\/customer-interface\/appointment'/);
  /* and #/customer-interface/actions already resolved — any key in the view list is accepted. */
  assert.match(appJs, /CUSTOMER_INTERFACE_VIEWS_V296\.some\(view=>view\[0\]===ciRequestedViewV368\)/);
});

/* ------------------------------------------------ photos 1, 3, 4: the offer cards ------------ */

test('v417 an offer card is one fixed shape at every width', () => {
  assert.match(ruleFor('.customer-promotion-card-media'), /aspect-ratio:16\/9/);
  assert.match(ruleFor('.customer-promotion-card-media img'), /object-fit:cover/);
  assert.match(ruleFor('.customer-home-offer-media'), /aspect-ratio:16\/9/);
  assert.match(ruleFor('.customer-home-offer-media img'), /object-fit:cover/);
  /* Three per-breakpoint ratios WERE the unevenness photo 4 objected to. */
  assert.doesNotMatch(html, /\.customer-home-offer-media\{aspect-ratio:1\.55\/1\}/);
  assert.doesNotMatch(html, /\.customer-home-offer-media\{aspect-ratio:1\.45\/1\}/);
  assert.doesNotMatch(html, /\.customer-home-offer-media\{aspect-ratio:auto;height:130px\}/);
});

test('v417 opening an offer still shows the photo whole', () => {
  assert.match(ruleFor('.customer-offer-detail-media img'), /object-fit:contain/);
  assert.match(html, /\.customer-reward-offer-page-v339 \.customer-promotion-card-media img\{[^}]*object-fit:contain/);
});

test('v417 the offers strip is centred, not shifted 16px left', () => {
  /* MEASURED at 375/390/412 before the fix: track left -16, right viewport-16 — the whole strip
     displaced left, which is the cut the owner drew. max-width:100vw clamped the width so the
     full-bleed pull could never be paid back on the right. After: -16 to viewport+16. */
  const rule = ruleFor('.customer-business-profile-v346 .customer-reward-offer-track-v339');
  assert.match(rule, /margin-inline:-16px/);
  assert.match(rule, /padding-inline:16px/);
  assert.doesNotMatch(rule, /max-width:100vw/, 'the clamp is what broke the bleed');
});

test('v417 a short offer card no longer stretches to its tallest neighbour', () => {
  assert.match(ruleFor('.customer-home-offers-track'), /align-items:flex-start/);
});

test('v417 the upload help promises what the app now does', () => {
  assert.match(appJs, /Cards show your photo in one fixed shape/);
  assert.match(appJs, /tapping the offer shows your photo whole/);
});

/* ------------------------------------------------ photo 2: the offer dialog kicker ----------- */

test('v417 the offer dialog does not name the offer three times', () => {
  const dialog = statement('id="customerOfferDetailClose"', '</button></div>');
  assert.doesNotMatch(dialog, /Limited-time offer · /);
  assert.match(dialog, /aria-label="Close offer details"/, 'the close control is untouched');
});

/* ------------------------------------------------ photos 6 and 7: name, sector, bio ---------- */

test('v417 the sector emoji follows the sector into the customer app', () => {
  const resolve = new Function('INDUSTRIES', `
    ${statement('function customerSectorEmojiV417(', '\n}')}
    return customerSectorEmojiV417;`)({ facial: { em: '✨', label: 'Facial / Spa' } });
  assert.equal(resolve('facial'), '✨', 'the stored key');
  assert.equal(resolve('Facial / Spa'), '✨', 'and the resolved label the customer read carries');
  assert.equal(resolve('something a firm typed'), '', 'no guess for wording we do not own');
});

test('v417 a firm\'s own wording is never decorated, and the bio reads under the name', () => {
  const tagline = new Function('esc', 'INDUSTRIES', `
    ${statement('function customerSectorEmojiV417(', '\n}')}
    ${statement('function customerBusinessTaglineV385(', '\n}')}
    return customerBusinessTaglineV385;`)(esc, { facial: { em: '✨', label: 'Facial / Spa' } });

  assert.match(tagline({ industry: 'Facial / Spa' }), /✨/);
  assert.doesNotMatch(tagline({ industry: 'Facial / Spa', industry_label: 'Facial studio' }), /✨/,
    'their own words, undecorated');
  const withBio = tagline({ industry: 'Facial / Spa', bio: 'We love cubbbbb' });
  assert.match(withBio, /customer-business-bio-v417/);
  assert.match(withBio, /We love cubbbbb/);
  assert.ok(withBio.indexOf('Facial / Spa') < withBio.indexOf('We love cubbbbb'),
    'sector first, then what the firm says about itself');
  assert.equal(tagline({}), '', 'neither one, no line at all');
  assert.doesNotMatch(tagline({ industry: 'Facial / Spa' }), /customer-business-bio-v417/,
    'an empty bio draws nothing');
});

test('v417 the bio actually reaches the customer, and the label stops promising a portal', () => {
  /* businesses.bio has existed since v325 and the workspace always wrote it; no customer read
     ever returned it, so every word was visible only to the firm that typed it. */
  assert.match(migration, /'bio', \(select b\.bio from public\.businesses b where b\.id = v_context\.business_id\)/);
  assert.match(appJs, /<label for="bbio">Company bio<\/label>/);
  assert.doesNotMatch(appJs, /Company bio \(shown on your portal\)/);
});

/* ------------------------------------------------ photo 8: rewards as a list ----------------- */

test('v417 rewards stack as rows, each with its own claim button', () => {
  const list = ruleFor('.wallet-rewards.customer-rewards-carousel-v337');
  assert.match(list, /display:grid/);
  assert.doesNotMatch(list, /overflow-x:auto/);
  assert.match(html, /\.customer-rewards-carousel-v337 \.wallet-reward-actions \.btn\{[^}]*min-height:44px/,
    'the QR button on every row is a real tap target');
  /* MEASURED at 390 and 768: three rewards, all three rows on screen, all three buttons visible,
     no horizontal scroll on the track or the page. */
});

test('v417 the "How rewards work" row is gone but its dismissal state is not orphaned', () => {
  assert.doesNotMatch(appJs, /\$\{customerPointsExplainerMarkupV167\(business\)\}/);
  /* The sheet and the per-customer localStorage key stay: people have that state on their
     devices, and deleting the writer would strand it. */
  assert.match(appJs, /peekaa\.customer\.points-explainer\.v1\./);
});

/* ------------------------------------------------ photo 9: the Messages gear ----------------- */

/* nestly_v548 (owner photo 2, the two settings blocks ringed with an arrow to a button drawn in
   the inbox head: "move inside this button"). The owner has reversed photo 9's ruling: the panel
   is collapsed behind a control again. The half of v417 that was never about the button survives
   verbatim and is what this test now guards — the gear was the panel's ONLY door, so deleting the
   two together would have taken a real choice from customers under the heading of a cosmetic
   tidy. A door that opens is not that. The panel is still rendered unconditionally; only its
   visibility moves, which is what keeps renderPreferences and the moved device card working. */
test('v417 the Messages settings are still reachable, now behind the v549 dialog', () => {
  assert.doesNotMatch(appJs, /customerInboxSettingsToggleV386/, 'the v386 gear is not resurrected');
  assert.match(appJs, /id="customerInboxSettingsV386" class="customer-inbox-settings-v386"/,
    'still rendered unconditionally, so the dialog has a live node to borrow');
  /* nestly_v613 (owner: "move here", with a gear drawn beside the page title). The door left the
     filter row for the page head. v417's point is untouched — the settings are still REACHABLE,
     which is the whole reason v417 refused to delete the control along with the panel. */
  assert.match(appJs, /id="customerInboxSettingsHeadV613"/, 'and it has a door');
  assert.match(appJs, /customerInAppInboxPreferences/, 'the reminder preferences survive');
  assert.match(appJs, /id="customerMessagesNotifications"/, 'and so does the device switch');
  assert.doesNotMatch(appJs, /settingsOpenV395/, 'the v395 open state stays dead');
  assert.doesNotMatch(appJs, /inboxSettingsOpenV548/, 'and so does v548 inline open state');
});

/* ------------------------------------------------ photo 11: the live preview ----------------- */

test('v417 the live preview shows the programmes the firm actually runs', () => {
  const preview = statement('function customerInterfaceLivePreviewMarkupV326(', '\n}');
  assert.match(preview, /const spineRowsV567=programmeSpineRowsV314\(\);/);
  assert.match(preview, /programmes:spineRowsV567/);
  assert.match(preview, /\.filter\(row=>row&&row\.active===true\)/,
    'a programme the owner switched off stops appearing here too');
  assert.match(preview, /liveBalanceUnitV378\(\)==='stamps'\?'stamps':'points'/,
    'a stamp-card firm is not told its customers collect points');
  /* nestly_v567: the hardcoded pair is GONE, fallback and all. v417 kept it "so the preview is
     never blank", which meant a stamps-only firm whose spine had not loaded was shown a points
     programme and a tier ladder under a badge saying this is what their customers see. An
     unreadable spine now fails closed: an explicit band, a retry, and no programme cards. */
  assert.doesNotMatch(preview, /\[\{kind:'points',customer_visible:true,active:true\},\{kind:'tiers'/);
  assert.match(preview, /if\(spineRowsV567===null\)\{/);
  assert.match(preview, /Could not load your live programme state/);
  assert.match(preview, /data-ci-preview-spine-retry-v567/);
  /* nestly_v541 (owner, photo 2, the real app beside the preview: "there's no rewards in actual
     customer app — why did you add it in?"). The badge changed with the section it described. The
     preview passes rewardsHost:false, so the real renderer correctly draws NO reward list — and
     v327 had bolted an invented one on at the bottom, at a position the customer app never uses.
     With that gone the preview is the owner's live input plus the customer app's own renderer,
     and the line now says that instead of promising a sample customer's balance and tier. */
  assert.match(preview, /Your business profile as customers see it, drawn by the customer app/,
    'the badge describes what the preview actually contains');
});
