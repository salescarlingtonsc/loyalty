/* nestly_v585 — the owner's 2026-08-29 batch: six numbered items plus the marks drawn on the
   photos themselves. The retargeted assertions live with the rulings they overturn (v173/v178/v386
   for the contact lines, v286/v289 for the profile); what is here is what had no earlier home.
   Item 4's other half — "the customer view has to change too" — is asserted here rather than
   changed: the customer app has printed the basis-specific noun since v189/v310, and the point of
   pinning it is that the business page can never drift away from it again. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const shell = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');
const cui = readFileSync(new URL('../../app/customer-ui.js', import.meta.url), 'utf8');
const sw = readFileSync(new URL('../../app/sw.js', import.meta.url), 'utf8');
const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start}`);
  return app.slice(from, to);
};

test('item 6 — a resolved media URL survives being resolved again', () => {
  /* THE BUG, confirmed against production: all three of Jess Salon's service photos were stored,
     customer_visible, version 1 — and the catalogue still said "Attach photo". The Services loader
     resolves the asset URL once and keeps it on the row; the row renderer resolves it again.
     Before v576 that was harmless (the same /object/public/ URL came back). Since v576 the return
     is a /render/image/ URL with a query string, which matched neither prefix, so the second pass
     returned '' — on every surface that resolves a value it has already resolved. */
  const helper = section('function customerMediaUrlV95(value){', 'function applyCustomerNavCountsV194');
  assert.match(helper, /const renderPrefixV585=/);
  assert.match(helper, /if\(raw\.startsWith\(renderPrefixV585\)\)return raw;/);
  /* The guard must come BEFORE the two prefix tests, or it can never be the thing that saves a
     second pass. */
  assert.ok(helper.indexOf('renderPrefixV585') < helper.indexOf('const relative=raw.startsWith'));
});

test('items 1 and 2 (photos 1 and 2) — one contact builder, carrying the owner’s two marks', () => {
  assert.match(app, /const CUSTOMER_CONTACT_PIN_V585='\\uD83D\\uDCCD'/);
  assert.match(app, /const CUSTOMER_CONTACT_PHONE_V585='\\u260E\\uFE0F'/);
  const lines = section('function customerBranchContactLinesV386(branch={}){', '/* v194 (owner struck');
  assert.match(lines, /CUSTOMER_CONTACT_PIN_V585[\s\S]{0,200}esc\(branch\.address\)/);
  assert.match(lines, /CUSTOMER_CONTACT_PHONE_V585[\s\S]{0,200}tel:/);
  /* The marks are decoration: the address and the number already say what they are, and a screen
     reader announcing "round pushpin" first is noise. */
  assert.match(lines, /class="customer-contact-mark-v585" aria-hidden="true"/);
  /* And the offer sheet no longer keeps a second copy that can drift — which is how photo 2 came
     to have a calendar glyph and a bare number in the first place. */
  const sheet = section('function showCustomerOfferDetailV173', 'function wireCustomerHomeOffersV167');
  assert.match(sheet, /host\.innerHTML=customerBranchContactLinesV386\(branch\)\|\|'';/);
  assert.doesNotMatch(sheet, /CUI\.icon\('bookings',\{size:16\}\) \$\{esc\(branch\.address\)\}/);
});

test('photo 4 — the offer sheet’s business mark opens that business', () => {
  const sheet = section('function showCustomerOfferDetailV173', 'function wireCustomerHomeOffersV167');
  assert.match(sheet, /customer-offer-detail-brandlink-v585" href="#\/wallet\/\$\{slug\}" data-offer-detail-nav/);
  /* With no slug it stays a plain mark rather than becoming a control that goes nowhere. */
  assert.match(sheet, /\$\{slug\?`<a class="customer-offer-detail-brand-v583/);
  assert.match(sheet, /:`<div class="customer-offer-detail-brand-v583">/);
  /* data-offer-detail-nav is what hands the sheet's own history entry to the destination, so Back
     returns to the page behind the sheet instead of reopening it. */
  assert.match(app, /overlay\.querySelectorAll\('\[data-offer-detail-nav\],\[data-business-detail-nav\]'\)/);
});

test('items 2 and 3 (photos 3 and 7) — Settings is a page, and "You" is gone', () => {
  const profile = section('async function renderCustomerProfile(requestedView){', 'async function renderCustomerQrJoin');
  assert.doesNotMatch(profile, /customer-profile-group-v3">You</);
  // The gear is a link to a real route, not a toggle.
  assert.match(profile, /id="customerProfileSettingsGearV583" href="#\/customer\/settings"/);
  assert.doesNotMatch(profile, /profileGearV583\.onclick/);
  assert.match(app, /if\(h==='#\/customer\/settings'\)return renderCustomerProfile\('settings'\);/);
  // Both halves stay in the DOM, one hidden — every card below is bound by id after this render.
  assert.match(profile, /<div id="customerProfilePersonalV585"\$\{settingsViewV585\?' hidden':''\}>/);
  assert.match(profile, /<div id="customerProfileSettingsV583"\$\{settingsViewV585\?'':' hidden'\}>/);
  // And a signed-out deep link to it is remembered through sign-in, like the profile it belongs to.
  assert.match(app, /'#\/customer\/settings'\n\]\);/);
});

test('item 3 — the gear is a cog that survives being 20px', () => {
  assert.match(cui, /settings:'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6M10\.7 3\.6h2\.6/);
  assert.doesNotMatch(cui, /settings:'M12 15\.5a3\.5/);
  /* customer-ui.js is PRECACHED by the service worker, so its ?v= token and CACHE_VERSION move
     together or the old glyph keeps being served. */
  assert.match(shell, /customer-ui\.js\?v=20260829-v585-settings-cog/);
  assert.match(sw, /const CACHE_VERSION='v23-20260829-v585'/);
});

test('photo 5 — the date chip stops eating the row, and the booking date is top right', () => {
  assert.match(shell, /\.customer-booking-head-v577 \.customer-datesheet-chip-v3\{width:auto/);
  assert.match(shell, /\.customer-booking-head-v577 \.customer-booking-search-v577\{order:3;flex:1 1 140px/);
  /* v581's two-column reflow is what put the date and the button on a second line under the
     address; the three-column shape holds at every width now. */
  assert.doesNotMatch(shell, /\.customer-booking-row-v580\{grid-template-columns:auto minmax\(0,1fr\);row-gap:10px\}/);
  assert.match(shell, /\.customer-booking-row-date-v580\{font-size:11\.5px\}/);
});

test('photo 6 — a ready reward is a gift, not a star', () => {
  const card = section('function customerProgrammeTileMarkupV96', 'function customerBusinessCategoryV122');
  assert.match(card, /customerProgrammeRewardReadyV392\(card\)\?`[\s\S]{0,900}CUI\.icon\('giftcard',\{size:16\}\)/);
  assert.doesNotMatch(card, /CUI\.icon\('star',\{size:16\}\)<span>\$\{esc\(status\)\}/);
});

test('item 4 (photo 8) — every figure on the tiers page follows the stored basis', () => {
    assert.match(app, /const growTiersUnitWordV585=/);
  assert.match(app, /const growTiersThresholdLabelV585=/);
  /* Spend is DOLLARS — the server compares the threshold against sum(amount_cents)/100 — and the
     column is an integer, so the field says whole dollars rather than inviting cents it would
     round away. */
  assert.match(app, /\?`Required spend \(\$\{S\.biz\.currency\|\|'SGD'\}\)`/);
  assert.match(app, /growTiersBasisIsSpendV585\?money\(Math\.round\(amount\*100\)\)/);
  assert.match(app, /placeholder="\$\{esc\(growTiersThresholdPlaceholderV585\)\}"/);
  // Nothing on the page may print a bare "points" for a rung any more.
  assert.doesNotMatch(app, /Reached at \$\{threshold\} points/);
  assert.doesNotMatch(app, /<small>\$\{Math\.max\(0,Number\(tier\.threshold\|\|0\)\)\} points<\/small>/);
  assert.doesNotMatch(app, />Required points<\/label>/);
  // Changing the basis does not rewrite the rungs, so the owner is told what their numbers mean now.
  assert.match(app, /kept \$\{rungsV585===1\?'its':'their'\} number/);
});

test('item 4 — and the customer app was already saying the same words', () => {
  /* Asserted, not changed. The canonical tier resolver returns `basis` with every payload and
     these two have printed the matching noun since v189/v310 — which is exactly why the business
     page saying "points" over a visits ladder was a contradiction the customer could see. */
  const requirement = section('function customerTierRequirementTextV189(threshold,basis){', 'function customerTierRemainingTextV186');
  assert.match(requirement, /basis==='spend'/);
  assert.match(requirement, /basis==='points_earned'/);
  assert.match(requirement, /visit\$\{value===1\?'':'s'\}/);
  const remaining = section('function customerTierRemainingTextV186(remaining,basis){', '/* v194: Tier and Reward points');
  assert.match(remaining, /basis==='spend'/);
  assert.match(remaining, /points to go/);
  assert.match(remaining, /visit\$\{visits===1\?'':'s'\} to go/);
});

test('item 5 (photo 9) — Referrals has the back button every other page has', () => {
  const page = section('async function referralsPage(){', '\nasync function ');
  assert.match(page, /grow-breadcrumb-row-v585/);
  assert.match(page, /grow-breadcrumb-back-v346" href="#\/grow" aria-label="Back to Rewards Programme"/);
  assert.match(shell, /\.grow-breadcrumb-row-v585\{display:flex/);
});
