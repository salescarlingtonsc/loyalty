import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const indexHtml = await read('app/index.html');
const appJs = await read('app/app.js');
const customerUi = await read('app/customer-ui.js');
const app = `${indexHtml}\n${appJs}`;

function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

/* ------------------------------------------- 1 · a glance at what is about to expire, on Home */

const expiring = section(appJs, 'function customerExpiringRewardsMarkupV195', 'function customerHomeOffersMarkupV167');

const renderExpiring = new Function('esc', 'ct', 'CUI', 'customerPointTotalV103', 'walletDate', `
  ${expiring}
  return customerExpiringRewardsMarkupV195;`)(
  (value) => String(value ?? ''), () => 'Local business', { icon: () => '' },
  (value) => String(value), (value) => `on ${String(value).slice(0, 10)}`);

test('Home leads with the points that are about to expire', () => {
  const html = renderExpiring([
    { business: { name: 'Cubbly' }, loyalty: { unit: 'points' },
      expiry: { expiring_units: 120, expiring_within_7_days: 120, next_expiry_at: '2026-08-12T00:00:00+08:00' } },
    { business: { name: 'Kopi Tiam' }, loyalty: { unit: 'points' },
      expiry: { expiring_units: 60, expiring_within_7_days: 0, next_expiry_at: '2026-09-01T00:00:00+08:00' } }
  ]);
  assert.match(html, /Expiring rewards/);
  assert.match(html, /120 points/);
  assert.match(html, /Cubbly/);
  assert.match(html, /2 to use/);
  // soonest first, and only the within-7-days row is marked urgent
  assert.ok(html.indexOf('Cubbly') < html.indexOf('Kopi Tiam'));
  assert.equal((html.match(/customer-expiring-when is-urgent/g) || []).length, 1);
});

test('a customer with nothing expiring is told that, not shown an empty box', () => {
  const html = renderExpiring([
    { business: { name: 'Cubbly' }, loyalty: { unit: 'points' }, expiry: { mode: 'none' } }
  ]);
  assert.match(html, /None of your points expire in the next 30 days/);
  assert.match(html, /Nothing in 30 days/);
});

test('a customer with no reward accounts at all gets no glance', () => {
  assert.equal(renderExpiring([]), '');
  assert.equal(renderExpiring(null), '');
});

test('the glance sits ahead of the offers, on Home only, from data Home already has', () => {
  const render = section(appJs, 'function renderActionableWalletHome', 'async function renderCustomerWallet');
  assert.match(render, /\$\{isHome\?`\$\{customerExpiringRewardsMarkupV195\(cards\)\}\s*\n\s*\$\{customerHomeOffersMarkupV167\(offersState\)\}/);
  assert.doesNotMatch(expiring, /sb\.rpc|customerRpc/, 'the glance must not cost a round trip');
});

/* ------------------------------------------------------ 2 · My Rewards: search, and no subtitle */

test('My Rewards can be searched by company name', () => {
  assert.match(appJs, /id="customerProgrammeSearch" type="search"/);
  assert.match(appJs, /placeholder="Search company name"/);
  assert.match(appJs, /data-programme-name="\$\{esc\(String\(business\.name\|\|''\)\.toLowerCase\(\)\)\}"/);
  const wire = section(appJs, 'function wireCustomerProgrammeSearchV195', 'function customerHomeFallbackActionV167');
  assert.doesNotMatch(wire, /sb\.rpc|customerRpc|renderCustomer/, 'typing must never re-read the wallet');
  assert.match(wire, /No reward account matches/);
  assert.match(wire, /group\.hidden=!visible/, 'an empty category must not leave a stranded heading');
});

test('the filter hides only what does not match, and restores everything when cleared', () => {
  const wire = section(appJs, 'function wireCustomerProgrammeSearchV195', 'function customerHomeFallbackActionV167');
  const tiles = [
    { dataset: { programmeName: 'cubbly' }, hidden: false },
    { dataset: { programmeName: 'kopi tiam tyeh' }, hidden: false }
  ];
  const status = { hidden: true, textContent: '' };
  const input = { value: '', listeners: [], addEventListener(_, fn) { this.listeners.push(fn); } };
  const group = { hidden: false, querySelectorAll: () => tiles };
  const host = {
    querySelector: (sel) => sel === '#customerProgrammeSearch' ? input
      : sel === '#customerProgrammeSearchStatus' ? status : null,
    querySelectorAll: (sel) => sel === '.customer-programme-category' ? [group] : tiles
  };
  new Function('host', `${wire}; wireCustomerProgrammeSearchV195(host)`)(host);
  const type = (value) => { input.value = value; input.listeners.forEach((fn) => fn()); };

  type('kopi');
  assert.deepEqual(tiles.map((tile) => tile.hidden), [true, false]);
  assert.equal(status.textContent, '1 of 2 shown');
  type('zzz');
  assert.deepEqual(tiles.map((tile) => tile.hidden), [true, true]);
  assert.match(status.textContent, /No reward account matches/);
  assert.equal(group.hidden, true);
  type('');
  assert.deepEqual(tiles.map((tile) => tile.hidden), [false, false]);
  assert.equal(group.hidden, false);
  assert.equal(status.hidden, true);
});

test('the "N linked reward accounts" subtitle is gone, along with its helper', () => {
  assert.doesNotMatch(appJs, /customerLinkedRewardsLabelV156/);
  assert.doesNotMatch(appJs, /linked reward account\$\{/);
});

/* ------------------------------------------------------------ 3 · Scan QR is an action, not a tab */

test('the scanner is the raised centre of the nav (v244 Grab-style revamp)', () => {
  /* v195 moved Scan to the header; the owner's v244 reference put it back in the nav as the
     signature centre control. v248 then hid Explore from customers, so four slots show today —
     Scan is still the centre of what they see. */
  const nav = section(appJs, 'const CUSTOMER_PRIMARY_NAV=Object.freeze([', 'function customerPrimaryNavigation(');
  assert.equal((nav.match(/\{key:/g) || []).length, 6);
  assert.match(appJs, /const CUSTOMER_EXPLORE_LIVE_V248=false;/);
  assert.match(nav, /\{key:'scan',icon:'scan',copy:'scanQr'\}/);
  assert.match(nav, /\{key:'explore',href:'#\/customer\/explore',icon:'search',copy:'explore'\}/);
  assert.ok(nav.indexOf("key:'programmes'") < nav.indexOf("key:'scan'"), 'Scan sits in the centre');
  assert.ok(nav.indexOf("key:'scan'") < nav.indexOf("key:'explore'"));
  assert.match(appJs, /id="customerNavScan" class="customer-nav-scan"/);
  assert.match(appJs, /if\(\$\('customerNavScan'\)\)\$\('customerNavScan'\)\.onclick=openCustomerJoinScanner/);
  assert.doesNotMatch(appJs, /customer-head-scan/, 'the header no longer duplicates the scanner');
  assert.match(indexHtml, /\.customer-primary-nav\{[^}]*grid-template-columns:1fr 1fr auto 1fr 1fr;/);
  assert.match(indexHtml, /\.customer-nav-scan-fab\{[^}]*border-radius:999px;background:var\(--grad\)/);
});

/* --------------------------------------------------------------- 4 · tier rungs and tab pictograms */

test('each rung carries a pictogram: star at the bottom, gem at the top, crown between', () => {
  const icon = new Function(`${section(appJs, 'function customerTierRungIconV195', 'function customerTierMilestonesMarkupV194')}
    return customerTierRungIconV195;`)();
  assert.equal(icon(0, 3), 'star');
  assert.equal(icon(1, 3), 'crown');
  assert.equal(icon(2, 3), 'diamond');
  // a two-rung and a five-rung ladder read the same way
  assert.equal(icon(0, 2), 'star');
  assert.equal(icon(1, 2), 'diamond');
  assert.deepEqual([0, 1, 2, 3, 4].map((index) => icon(index, 5)),
    ['star', 'crown', 'crown', 'crown', 'diamond']);
  for (const name of ['crown', 'diamond']) assert.match(customerUi, new RegExp(`\\n\\s+${name}:'M`));
});

test('the pictogram is inside the rung marker and stays legible on the coral fill', () => {
  assert.match(appJs, /<i>\$\{CUI\.icon\(customerTierRungIconV195\(index,rungs\.length\),\{size:16\}\)\}<\/i>/);
  assert.match(indexHtml, /\.customer-tier-milestone\.is-current i\{[^}]*color:#fff/);
  assert.match(indexHtml, /\.customer-tier-milestone\.is-achieved i\{[^}]*color:#fff/);
});

test('both tabs carry a pictogram beside their name', () => {
  assert.match(appJs, /data-programme-tab="tier"[^>]*>\$\{CUI\.icon\('star',\{size:16\}\)\}<span>Tier<\/span>/);
  assert.match(appJs, /data-programme-tab="points"[^>]*>\$\{CUI\.icon\('redeem',\{size:16\}\)\}<span>Reward points<\/span>/);
});

test('the programme header no longer repeats the programme name', () => {
  const merchant = section(appJs, 'function customerMerchantExperienceMarkupV95', 'function actionableWalletCardMarkup');
  const identity = section(merchant, '<button class="customer-programme-identity"', '</button>');
  /* v327: the name computation moved into a `headV327` variable (declared once, used for both
     the button's aria-label and its visible text) so the two can never disagree — the guard here
     is now on that variable's own definition, not on an inline expression inside the button. */
  assert.match(merchant, /const headV327=esc\(business\.name\|\|presentation\.name\);/,
    'the company name stays, computed once');
  assert.doesNotMatch(identity, /esc\(presentation\.name\)/,
    '"Cubbly Stamp" under "Cubbly" told the customer nothing they had not just read');
  assert.match(identity, /\$\{headV327\}/, 'the identity button uses the shared name variable');
  /* v326 (owner mockup: cover photo, logo, name and Book now on one row; phone/address of their
     own beneath): "Address, phone and offers ›" moved out of the identity button into its own
     contact area below, which loads real phone/address inline and falls back to this same link
     when they are not yet available. */
  assert.doesNotMatch(identity, /customer-programme-contact-item-v337/,
    'the identity button itself is now just logo, name and tier — the contact row moved below it');
  /* v337 (owner mockup "photo 1"): the single "Address, phone and offers ›" link and separate
     Book now button became three tappable segments — Address, Call, Book now — still opening
     the same company sheet / tel: link / booking href as before. */
  assert.match(merchant, /customer-programme-contact-row-v337/);
  assert.match(merchant, />Address<\/span>/);
  assert.match(merchant, />Call<\/span>/);
});

/* ------------------------------------------- 5 · the standalone Rewards card, and where it went */

test('redemption lives under the balance that pays for it, not in a card of its own', () => {
  assert.match(appJs, /\$\{rewardsHost\?'<div id="walletRewards" class="customer-programme-rewards"/);
  assert.match(appJs, /rewardsHost:capabilities\.rewards===true/,
    'the capability gate is unchanged — no rewards capability, no reward host');
  assert.doesNotMatch(appJs, /capabilities\.rewards\?walletSectionShell/);
  // the repeated balance and the three-step strip are gone
  assert.doesNotMatch(appJs, /wallet-reward-steps/);
  assert.doesNotMatch(indexHtml, /wallet-reward-steps/);
  assert.doesNotMatch(appJs, /You have <b>\$\{esc\(customerPointTotalV103\(rewardBalance\)\)\}/);
  // what must NOT be lost: the redeem control itself
  assert.match(appJs, /data-customer-redeem="\$\{esc\(r\.action_key\)\}"/);
  assert.match(appJs, /Pick a reward, then show its QR at the counter/);
});

/* ---------------------------------------------------------------- 6 · Bookings: filter and photo */

test('bookings can be narrowed to a date range, in Singapore time', () => {
  /* v196 (owner: "i need the date to date filter"): the fixed windows are gone — a customer
     looking for the visit they made in March could not ask for March. */
  const range = new Function(`${section(appJs, 'function customerBookingRangeBoundV195', 'function customerBookingNormaliseRangeV196')}
    return customerBookingWithinRangeV196;`)();
  const at = (day, hour = '10:00') => `2026-03-${day}T${hour}:00+08:00`;

  assert.equal(range(at('15'), { from: '2026-03-01', to: '2026-03-31' }), true);
  assert.equal(range(at('15'), { from: '2026-04-01', to: '2026-04-30' }), false);
  // either bound on its own
  assert.equal(range(at('15'), { from: '2026-03-16', to: '' }), false);
  assert.equal(range(at('15'), { from: '2026-03-15', to: '' }), true);
  assert.equal(range(at('15'), { from: '', to: '2026-03-14' }), false);
  assert.equal(range(at('15'), { from: '', to: '2026-03-15' }), true);
  // both bounds are inclusive across the whole SGT day — 11:59pm on the closing day is in
  assert.equal(range(at('31', '23:59'), { from: '2026-03-01', to: '2026-03-31' }), true);
  assert.equal(range(at('01', '00:00'), { from: '2026-03-01', to: '2026-03-31' }), true);
  // no range at all keeps everything
  assert.equal(range(at('15'), { from: '', to: '' }), true);
  assert.equal(range(at('15'), {}), true);
  // a malformed date is not a filter
  assert.equal(range(at('15'), { from: 'last March', to: '' }), true);
});

test('an inverted range is swapped rather than shown as "no bookings"', () => {
  const normalise = new Function(`${section(appJs, 'function customerBookingRangeBoundV195', 'function customerBookingFilterMarkupV195')}
    return customerBookingNormaliseRangeV196;`)();
  assert.deepEqual(normalise({ from: '2026-03-31', to: '2026-03-01' }), { from: '2026-03-01', to: '2026-03-31' });
  assert.deepEqual(normalise({ from: '2026-03-01', to: '2026-03-31' }), { from: '2026-03-01', to: '2026-03-31' });
  assert.deepEqual(normalise({ from: '2026-03-01', to: '' }), { from: '2026-03-01', to: '' });
  assert.deepEqual(normalise({}), { from: '', to: '' });
});

test('a booking with no usable time is never silently hidden by the filter', () => {
  const range = new Function(`${section(appJs, 'function customerBookingRangeBoundV195', 'function customerBookingNormaliseRangeV196')}
    return customerBookingWithinRangeV196;`)();
  for (const value of ['', null, undefined, 'sometime next week']) {
    assert.equal(range(value, { from: '2026-03-01', to: '2026-03-31' }), true);
  }
});

test('the date filter is client-side over records already fetched', () => {
  const bookings = section(appJs, 'async function renderCustomerBookings', 'async function renderCustomerMessages');
  assert.match(appJs, /function customerBookingFilterMarkupV195/);
  assert.match(bookings, /customerBookingTabGroupsV178\(allGroups,currentBookingTab,currentBookingRange\)/);
  assert.match(bookings, /currentBookingRange=customerBookingNormaliseRangeV196\(next\)/);
  assert.match(appJs, /<input id="customerBookingFrom" type="date"/);
  assert.match(appJs, /<input id="customerBookingTo" type="date"/);
  assert.match(appJs, /id="customerBookingRangeClear"/, 'a set range must be clearable in one tap');
  assert.doesNotMatch(bookings, /p_window|p_within|p_from|p_to\b/, 'the range must not become a server argument');
  /* Top-20 #19: the 44px touch target moved from the bare inputs to the chip that opens them;
     the inputs keep their own 44px inside the panel. */
  assert.match(indexHtml, /\.customer-datesheet-chip-v3\{[^}]*min-height:44px/);
  assert.match(indexHtml, /\.customer-datesheet-v3 input\[type="date"\]\{[^}]*min-height:44px/);
});

/* Top-20 #19 ("the most clinical, least branded element in the customer app"): the raw native
   date pair became one chip that reads its own state over an inline panel holding the SAME two
   inputs. Filtering stays live on change, so Apply may only close the panel. */
test('the date chip says what the filter is doing, and Apply is not a second filter path', () => {
  const label = new Function(`${section(appJs, 'function customerBookingRangeBoundV195', 'function customerBookingWithinRangeV196')}
    ${section(appJs, 'function customerBookingRangeChipLabelV3', 'function customerBookingFilterMarkupV195')}
    return customerBookingRangeChipLabelV3;`)();
  assert.equal(label({ from: '', to: '' }), 'Any dates');
  assert.equal(label(), 'Any dates');
  assert.equal(label({ from: '2026-08-12', to: '2026-08-19' }), '12 Aug – 19 Aug');
  assert.equal(label({ from: '2026-08-12', to: '' }), 'From 12 Aug');
  assert.equal(label({ from: '', to: '2026-08-19' }), 'Until 19 Aug');
  assert.equal(label({ from: 'not-a-date', to: '' }), 'Any dates');

  const markup = section(appJs, 'function customerBookingFilterMarkupV195', 'function customerBookingBusinessLogoV195');
  assert.match(markup, /id="customerBookingRangeChip"[^>]*aria-expanded="\$\{open\?'true':'false'\}"[^>]*aria-controls="customerBookingDatePanel"/);
  assert.match(markup, /<div class="customer-datesheet-v3" id="customerBookingDatePanel" role="group"[^>]*\$\{open\?'':' hidden'\}>/,
    'the panel stays closed until the chip is pressed');
  /* The inputs MOVED into the panel — they were not recreated, so the wiring above still finds
     them by the same ids. */
  assert.ok(markup.indexOf('id="customerBookingDatePanel"') < markup.indexOf('id="customerBookingFrom"'));
  assert.ok(markup.indexOf('id="customerBookingFrom"') < markup.indexOf('id="customerBookingRangeApply"'));

  const bookings = section(appJs, 'async function renderCustomerBookings', 'async function renderCustomerMessages');
  assert.match(bookings, /if\(fromInput\)fromInput\.onchange=\(\)=>applyRange/, 'filtering stays live on change');
  assert.match(bookings, /applyRangePanel\.onclick=\(\)=>setRangePanelOpenV3\(false,'customerBookingRangeChip'\)/,
    'Apply only closes the panel — it must not run a second, different filter');
  assert.match(bookings, /if\(event\.key!=='Escape'\|\|!bookingRangePanelOpenV3\)return/, 'Escape closes the panel');
  assert.match(bookings, /customerBookingFilterMarkupV195\(currentBookingRange,bookingRangePanelOpenV3\)/,
    'the open state survives the repaint every filter change causes');
});

test('a booking is headed by the company’s own photo, with an honest fallback', () => {
  const logo = section(appJs, 'function customerBookingBusinessLogoV195', 'function customerBookingTabGroupsV178');
  assert.match(logo, /customerMediaUrlV95\(group\?\.business_logo\)/, 'the media allowlist still applies');
  assert.match(logo, /customer-booking-logo--fallback/);
  assert.match(appJs, /if\(!group\.business_logo\)group\.business_logo=String\(business\.logo_url\|\|''\)/);
  assert.match(appJs, /customer_get_programme_selector_media_v96/);
  assert.match(appJs, /<div class="wallet-section-head">\$\{customerBookingBusinessLogoV195\(group\)\}/);
});

/* --------------------------------------------------- 7 · the offer sheet: no echoes, book, profile */

const echo = new Function(`${section(appJs, 'function customerOfferTaglineV194', 'function showCustomerOfferDetailV173')}
  return {tagline:customerOfferTaglineV194,description:customerOfferDescriptionV195};`)();

test('a line that only repeats the offer title is dropped, on the card as well as the sheet', () => {
  assert.equal(echo.tagline('National Day: 50% off first prata', '50% off first prata'), '');
  assert.equal(echo.tagline('50% off first prata', 'National Day: 50% off first prata'), '');
  assert.equal(echo.tagline('National Day: 50% off first prata', 'Dine in only'), 'Dine in only');
  assert.match(appJs, /facts=customerOfferTaglineV194\(item\?\.name,String\(item\?\.metadata\?\.offer_facts\|\|''\)\)/);
  assert.match(appJs, /factsV195=customerOfferTaglineV194\(item\?\.name,String\(item\?\.metadata\?\.offer_facts\|\|''\)\)/);
});

test('only the sentences this app generated are trimmed from a description', () => {
  assert.equal(
    echo.description('Celebrate National Day with 50% off first prata at Cubbly. Available until 31 August 2026. View the offer and plan your visit.'),
    'Celebrate National Day with 50% off first prata at Cubbly.');
  assert.equal(
    echo.description('Enjoy 20% off. Available until 30 August 2026. Book now to enjoy this offer.'),
    'Enjoy 20% off.');
  assert.equal(
    echo.description('Enjoy 20% off. Show this offer at the counter when you visit.'),
    'Enjoy 20% off.');
  // a merchant's own words, including their own dates, survive untouched
  const merchantCopy = 'Available until stocks last. Our chef picks the fish each morning.';
  assert.equal(echo.description(merchantCopy), merchantCopy);
  assert.equal(echo.description('Free kopi with every set. Ends 31 Aug.'), 'Free kopi with every set. Ends 31 Aug.');
  assert.equal(echo.description(''), '');
});

test('an offer can be booked from the sheet, and only when the business allows booking', () => {
  const sheet = section(appJs, 'function showCustomerOfferDetailV173', 'function wireCustomerHomeOffersV167');
  assert.match(sheet, /<span data-offer-book><\/span>/);
  assert.match(sheet, /customer_get_business_actions_v89/);
  assert.match(sheet, /if\(!host\|\|error\|\|data\?\.booking\?\.enabled!==true\)return/,
    'fail closed: an unknown booking state must not offer a button that will refuse the customer');
  assert.match(sheet, /host\.innerHTML=`<a class="btn" href="#\/b\/\$\{slug\}" data-offer-detail-nav>/);
  assert.match(sheet, /wireCustomerSheetNavV183\(host,deactivate\)/,
    'wiring the new link must not re-bind the links already wired');
});

test('the company row shows the address and phone, and opens the company profile', () => {
  const sheet = section(appJs, 'function showCustomerOfferDetailV173', 'function wireCustomerHomeOffersV167');
  assert.match(appJs, /data-company-detail aria-label="Open the company profile for \$\{esc\(name\)\}"/);
  assert.match(appJs, /<span class="muted small" data-company-row-lines>/);
  assert.match(sheet, /const summary=\[branch\.address,branch\.phone\]/);
  assert.match(sheet, /if\(summary\.length\)rowLines\.textContent=summary\.join\(' · '\)/,
    'a business with no address or phone keeps the honest default instead of an empty line');
  /* v326 (owner: "when I click this, straightaway go to company profile inside, don't need
     another pop-out"): the row now navigates straight to the business's own programme page
     instead of opening a second modal (showCustomerBusinessDetailV178). */
  assert.match(sheet, /const target=`#\/wallet\/\$\{encodeURIComponent\(business\.slug\|\|''\)\}`/);
  assert.doesNotMatch(sheet, /companyButton\.onclick=\(\)=>\{\s*const handOff=CUI\.currentDialogHistoryId\?\.\(\)\|\|0;\s*deactivate\(\{restoreFocus:false,handOffHistory:handOff>0\}\);\s*showCustomerBusinessDetailV178\(business,\{inheritHistoryId:handOff\}\);/,
    'the row no longer opens a second pop-out modal');
});

/* ---------------------------------------------------- 8 · v196 follow-ups on the same surfaces */

test('the header controls sit on one shared rhythm', () => {
  // owner: "qrcode and notification gap further than profile icon — please align it".
  // v244 then removed the header scanner entirely (it became the nav centre), which is the
  // strongest possible form of that alignment: nothing in the header carries its own margin.
  assert.match(indexHtml, /\.wallet-head\{[^}]*gap:12px/);
  assert.match(indexHtml, /#customerInboxBellSlot:empty\{display:none\}/,
    'an empty bell slot must not leave a double gap where the bell would be');
});

test('the expiring card is named for what it holds', () => {
  assert.match(appJs, /<span>Expiring rewards<\/span>/);
  assert.doesNotMatch(appJs, /<span>Expiring soon<\/span>/);
});

test('My Rewards no longer explains how to get what the customer already has', () => {
  // owner struck the whole "Joining a new rewards account" card out
  assert.doesNotMatch(appJs, /<b>Joining a new rewards account<\/b>/, 'the card is gone (the commit note recording why is not the card)');
  assert.doesNotMatch(appJs, /scanGuide/);
  assert.doesNotMatch(indexHtml, /customer-programme-guide/, 'its CSS went with it');
  // the rule it explained is unchanged, and the customer with NO accounts still gets it in full
  const quest = section(appJs, 'function renderCustomerFirstProgrammeQuest', 'function customerProgrammeGridMarkupV96');
  assert.match(quest, /ct\('qrOnlyHelp'\)/);
  assert.match(appJs, /customerMyRewardsHeadingV156\(cards\.length,\{scanId:'customerHomeScan'\}\)/,
    'Scan to join stays in the heading row');
});

test('History is a record, so it carries no count', () => {
  assert.match(appJs, /const CUSTOMER_BOOKING_TABS_WITHOUT_COUNT_V196=new Set\(\['history'\]\)/);
  assert.match(appJs, /showCount=!CUSTOMER_BOOKING_TABS_WITHOUT_COUNT_V196\.has\(tab\)/);
  assert.match(appJs, /\$\{showCount&&Number\(counts\[tab\]\)>0\?/);
  const tablist = new Function('esc', `${section(appJs, 'const CUSTOMER_BOOKING_TABS_WITHOUT_COUNT_V196', '\nasync function renderCustomerBookings')}
    ${section(appJs, 'const CUSTOMER_BOOKING_TABS_V178=[', 'const CANCELLED_CUSTOMER_BOOKING_STATUSES_V178')}
    return customerBookingTablistMarkupV178;`)((value) => String(value ?? ''));
  const html = tablist('bookings', { bookings: 2, cancelled: 3, history: 9 });
  assert.match(html, /Ongoing\s*<span class="customer-booking-tab-count">2/);
  assert.match(html, /Cancelled\s*<span class="customer-booking-tab-count">3/);
  assert.doesNotMatch(html, /History\s*<span class="customer-booking-tab-count">/);
  assert.doesNotMatch(html, />9</);
});

/* ------------------------------------- 9 · v230: the panel is built from the firm's chosen mode */

const modeApi = new Function('esc', 'ct', 'CUI', 'customerPointTotalV103',
  'customerTierPanelMarkupV194', 'customerRewardProgressMarkupV167', `
  ${section(appJs, 'function customerProgrammeModeV230', 'function customerProgrammeSummaryTabsV194')}
  ${section(appJs, 'function customerProgrammeSummaryTabsV194', 'function wireCustomerProgrammeTabsV194')}
  return {mode:customerProgrammeModeV230,render:customerProgrammeSummaryTabsV194};`)(
  (value) => String(value ?? ''), (value) => String(value ?? 'points'), { icon: () => '' },
  (value) => String(value), () => '<div data-tier-ladder></div>',
  // production returns '' when there is no next reward — the stub must too, or the fallback
  // line this test is about could never be reached.
  (card) => card?.next_eligible_reward ? '<div data-reward-progress></div>' : '');

test('the chosen mode decides the panel, and an unchosen firm keeps both', () => {
  assert.equal(modeApi.mode({ points_mode: 'tiers', tiers: true, rewards: false }), 'tiers');
  assert.equal(modeApi.mode({ points_mode: 'redeem', tiers: false, rewards: true }), 'redeem');
  assert.equal(modeApi.mode({ points_mode: null, tiers: true, rewards: true }), 'both');
  // the server's own choice wins over what the other flags happen to say
  assert.equal(modeApi.mode({ points_mode: 'tiers', tiers: false, rewards: true }), 'tiers');
  assert.equal(modeApi.mode({ points_mode: 'redeem', tiers: true, rewards: true }), 'redeem');
  // nothing known at all still renders something a customer can read
  assert.equal(modeApi.mode({}), 'redeem');
  assert.equal(modeApi.mode({ points_mode: null, tiers: true, rewards: false }), 'tiers');
});

test('a tiers firm shows tiers and benefits, and never a redemption it cannot honour', () => {
  const html = modeApi.render({
    tier: { basis: 'points_earned' }, loyalty: { balance: 300 }, presentation: { unit: 'points' },
    reward: { name: 'Free facial add-on', remaining_units: 200 },
    rewardsHost: false, capabilities: { points_mode: 'tiers', tiers: true, rewards: false }
  });
  assert.match(html, /data-tier-ladder/, 'the tier ladder and its benefits are the panel');
  assert.match(html, /300<\/b> <span class="muted">points earned/);
  assert.match(html, /count toward membership here — they are not spent/);
  assert.doesNotMatch(html, /walletRewards/, 'no reward host: the v229 gate would refuse redemption');
  assert.doesNotMatch(html, /data-programme-tab/, 'one mode, one panel — no tab to a dead end');
});

test('a redeem firm shows what its points buy, and no ladder it does not run', () => {
  const html = modeApi.render({
    tier: { basis: 'visits' }, loyalty: { balance: 300 }, presentation: { unit: 'points' },
    reward: { name: 'Free facial add-on', remaining_units: 200 },
    rewardsHost: true, capabilities: { points_mode: 'redeem', tiers: false, rewards: true }
  });
  assert.match(html, /id="walletRewards"/);
  assert.match(html, /data-reward-progress/);
  assert.doesNotMatch(html, /data-tier-ladder/);
  assert.doesNotMatch(html, /data-programme-tab/);
});

test('a firm that has not chosen keeps the two tabs it had before v230', () => {
  const html = modeApi.render({
    tier: {}, loyalty: { balance: 300 }, presentation: { unit: 'points' }, reward: null,
    rewardsHost: true, capabilities: { points_mode: null, tiers: true, rewards: true }
  });
  assert.match(html, /data-programme-tab="tier"/);
  assert.match(html, /data-programme-tab="points"/);
  assert.match(html, /data-tier-ladder/);
  assert.match(html, /id="walletRewards"/);
});

test('the same reward line is not printed twice', () => {
  const html = modeApi.render({
    tier: {}, loyalty: { balance: 300 }, presentation: { unit: 'points' },
    reward: { name: 'A thank-you on your next visits', available_now: true },
    rewardsHost: false, capabilities: { points_mode: 'redeem' }
  });
  assert.equal((html.match(/data-reward-progress/g) || []).length, 1,
    'the panel duplicated the "is ready to redeem" line the progress markup already prints');
  // the fallback only appears when there is no reward at all
  const empty = modeApi.render({
    tier: {}, loyalty: { balance: 0 }, presentation: { unit: 'points' }, reward: null,
    rewardsHost: false, capabilities: { points_mode: 'redeem' }
  });
  assert.match(empty, /Rewards from this business appear below as you earn/);
});

test('the mode comes from the server, so the surface and the redemption gate cannot disagree', () => {
  const migration = readFileSync(new URL('db/migrations/20260808_nestly_v231_capabilities_follow_the_points_mode.sql', root), 'utf8');
  assert.match(migration, /coalesce\(v_points_mode,'redeem'\) <> 'tiers'/, 'rewards off in tiers mode');
  assert.match(migration, /'points_mode', v_points_mode/);
  assert.match(migration, /coalesce\(v_points_mode,'tiers'\) = 'tiers'/);
  assert.match(migration, /revoke all on function public\.customer_portal_capabilities\(text\) from public, anon;/);
  assert.match(appJs, /rewardsHost:capabilities\.rewards===true,programmeCapabilities:capabilities/);
  assert.match(appJs, /capabilities:programmeCapabilities/);
  assert.doesNotMatch(appJs, /points_mode==='tiers'\?[^\n]*S\.biz/, 'the customer must not read a workspace value');
});

/* ------------------------------------------------------------------- v281 audit blocker pins */

test('the My Rewards search can actually hide things — [hidden] beats the display classes', () => {
  /* An author display declaration beats the UA sheet's [hidden]{display:none}; without these two
     rules the v195 search set the attribute and hid nothing. */
  assert.match(indexHtml, /\.customer-programme-card\[hidden\]\{display:none!important\}/);
  assert.match(indexHtml, /\.customer-programme-category\[hidden\]\{display:none!important\}/);
});

test('reaching #/join from #/join re-routes — same-hash nav() fires no hashchange', () => {
  /* Two real dead-ends: registration success (already at #/join) and rescanning from the
     expired-QR screen (also at #/join). Both must explicitly route(). */
  assert.equal((appJs.match(/if\(location\.hash==='#\/join'\)route\(\);else nav\('#\/join'\);/g) || []).length, 2);
});
