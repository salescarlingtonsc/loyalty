import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

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

test('the scanner moved to the header and the nav holds three destinations', () => {
  assert.match(appJs, /<button class="customer-head-scan" id="customerNavScan" type="button"/);
  assert.match(appJs, /if\(\$\('customerNavScan'\)\)\$\('customerNavScan'\)\.onclick=openCustomerJoinScanner/);
  const nav = section(appJs, 'const CUSTOMER_PRIMARY_NAV=Object.freeze([', 'function customerPrimaryNavigation(');
  assert.equal((nav.match(/\{key:/g) || []).length, 3);
  assert.doesNotMatch(nav, /key:'scan'/);
  assert.match(indexHtml, /\.customer-primary-nav\{[^}]*grid-template-columns:repeat\(3,minmax\(0,1fr\)\)/);
  assert.match(indexHtml, /\.customer-head-scan\{[^}]*min-width:44px;min-height:44px/);
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
  assert.match(appJs, /<i>\$\{CUI\.icon\(customerTierRungIconV195\(index,rungs\.length\),\{size:14\}\)\}<\/i>/);
  assert.match(indexHtml, /\.customer-tier-milestone\.is-current i\{[^}]*color:#fff/);
  assert.match(indexHtml, /\.customer-tier-milestone\.is-achieved i\{[^}]*color:#fff/);
});

test('both tabs carry a pictogram beside their name', () => {
  assert.match(appJs, /data-programme-tab="tier"[^>]*>\$\{CUI\.icon\('star',\{size:17\}\)\}<span>Tier<\/span>/);
  assert.match(appJs, /data-programme-tab="points"[^>]*>\$\{CUI\.icon\('redeem',\{size:17\}\)\}<span>Reward points<\/span>/);
});

test('the programme header no longer repeats the programme name', () => {
  const merchant = section(appJs, 'function customerMerchantExperienceMarkupV95', 'function actionableWalletCardMarkup');
  const identity = section(merchant, '<button class="customer-programme-identity"', '</button>');
  assert.doesNotMatch(identity, /esc\(presentation\.name\)/,
    '"Cubbly Stamp" under "Cubbly" told the customer nothing they had not just read');
  assert.match(identity, /\$\{esc\(business\.name\|\|presentation\.name\)\}/, 'the company name stays');
  assert.match(identity, /Address, phone and offers ›/);
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
  assert.match(indexHtml, /\.customer-booking-filter input\[type="date"\]\{[^}]*min-height:44px/);
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
  assert.match(sheet, /showCustomerBusinessDetailV178\(business,\{inheritHistoryId:handOff\}\)/);
});

/* ---------------------------------------------------- 8 · v196 follow-ups on the same surfaces */

test('the header controls sit on one shared rhythm', () => {
  // owner: "qrcode and notification gap further than profile icon — please align it"
  assert.doesNotMatch(indexHtml, /\.customer-head-scan\{[^}]*margin-right/,
    'the scan button carried its own margin on top of the header gap');
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
