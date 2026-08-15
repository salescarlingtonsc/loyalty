import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=(readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

test('customer Home removes the redundant Messages summary while retaining the header notification control',()=>{
  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  const fallbackHome=wallet.slice(wallet.indexOf("if(!businessSlug){"),wallet.indexOf("const args={p_business_slug:businessSlug}"));
  const shell=section('function renderCustomerShell','function focusCustomerRoute');

  assert.doesNotMatch(fallbackHome,/href="#\/customer\/messages"[\s\S]{0,100}<b>Messages<\/b>/);
  /* v194 (owner struck both cards off the Home screenshot): the two quick-link cards duplicated
     the bottom navigation, which is on every customer screen. The destinations did not go away —
     they are the nav tabs, which now also carry counts. */
  assert.doesNotMatch(app,/customerHomeQuickLinksV183/);
  assert.match(app,/href:'#\/customer\/programmes'/);
  assert.match(app,/href:'#\/customer\/bookings'/);
  assert.match(app,/applyCustomerNavCountsV194\(\{programmes:cards\.length,bookings:bookingsAvailable\?bookingCount:0\}\)/);
  assert.match(shell,/id="customerInboxBellSlot"/);
  assert.match(shell,/href="#\/customer\/messages"/);
  assert.match(shell,/CUI\.icon\('bell'/);
});

test('programme selector is exactly five compact columns on wide desktop with deliberate responsive breakpoints',()=>{
  assert.match(app,/\.customer-programme-category-grid\{display:grid;grid-template-columns:repeat\(5,minmax\(0,1fr\)\);gap:10px\}/);
  assert.match(app,/@media\(min-width:721px\) and \(max-width:1100px\)\{\.customer-programme-category-grid\{grid-template-columns:repeat\(3,minmax\(0,1fr\)\)\}\}/);
  assert.match(app,/@media\(max-width:720px\)\{[\s\S]*\.customer-programme-category-grid\{grid-template-columns:repeat\(2,minmax\(0,1fr\)\)\}/);
  assert.match(app,/@media\(max-width:420px\)\{\.customer-programme-category-grid\{grid-template-columns:1fr\}/);
  assert.match(app,/\.customer-programme-card-v95\{[^}]*min-height:152px/s);
  assert.match(app,/\.customer-programme-card\{[^}]*min-height:44px/s);
});

test('selector tiles use validated logos when supplied and deterministic initials otherwise',()=>{
  const helper=section('function customerProgrammeInitialsV96','function renderActionableWalletHome');
  const home=section('function renderActionableWalletHome','async function renderCustomerWallet');
  assert.match(helper,/customerMediaUrlV95\(business\?\.logo_url\)/);
  assert.match(helper,/<img src="\$\{esc\(logoUrl\)\}" alt="\$\{esc\(business\?\.name\|\|ct\('localBusiness'\)\)\} logo"/);
  assert.match(helper,/customerProgrammeInitialsV96\(business\?\.name\)/);
  assert.match(helper,/function customerProgrammeGridMarkupV96\(cards=\[\]\)/);
  assert.match(helper,/customerProgrammeTileLogoV96\(business\)/);
  assert.match(helper,/aria-label="\$\{esc\(ct\('openProgramme'/);
  assert.match(helper,/href="#\/wallet\/\$\{encodeURIComponent\(business\.slug/);
  assert.match(home,/customerProgrammeGridMarkupV96\(cards\)/);
  assert.doesNotMatch(home,/actionableWalletActionText\(card\)/);
});

test('fallback Home and legacy Programmes route reuse the compact selector instead of huge wallet cards',()=>{
  const programmes=section('async function renderCustomerProgrammes','const ACTIVE_CUSTOMER_BOOKING_REQUEST_STATUSES');
  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  const fallbackHome=wallet.slice(wallet.indexOf("if(!businessSlug){"),wallet.indexOf("const args={p_business_slug:businessSlug}"));
  assert.match(programmes,/Promise\.all\(\[\s*sb\.rpc\('customer_get_wallet'\),\s*sb\.rpc\('customer_get_programme_selector_media_v96'\)/);
  assert.match(programmes,/mergeCustomerProgrammeSelectorMediaV96/);
  assert.match(programmes,/customerProgrammeGridMarkupV96\(cards\)/);
  /* v183 (owner struck the My Rewards block off Home): the compact selector is reached from
     Home's jump-off now; only the My Rewards route renders the grid itself. */
  assert.doesNotMatch(fallbackHome,/customerProgrammeGridMarkupV96\(cards\)/);
  // v194: the jump-off is the permanent navigation, asserted above.
  assert.doesNotMatch(fallbackHome,/customerHomeQuickLinksV183/);
  assert.doesNotMatch(fallbackHome,/class="wallet-firms"|class="wallet-firm"/);
  assert.doesNotMatch(fallbackHome,/data-slug=/);
});

test('merchant feature groups and birthday participation render only from actual capability and content',()=>{
  const merchant=section('function customerMerchantExperienceMarkupV95','function actionableWalletCardMarkup');
  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  assert.doesNotMatch(merchant,/presentation\.rewards\.length|presentation\.rewards\.map/,
    'authoritative wallet rewards are the only reward cards on programme detail');
  assert.match(merchant,/presentation\.products\.length\|\|presentation\.services\.length\?/);
  assert.match(merchant,/presentation\.benefits\.length\?`<div class="customer-section-title"/);
  // v173 raised the customer offer shelf from 2 to 6.
  assert.match(merchant,/const offers=\(Array\.isArray\(presentation\.offers\)\?presentation\.offers:\[\]\)\.slice\(0,6\)/);
  // v167 moved the offers shelf into a shared renderer (one section, one empty state) instead of
  // an inline conditional per surface. v339 moved that shelf again — the offer cards are now the
  // pages after the reward banner in the swipe region — but the property this line guards is the
  // same: ONE renderer is handed the same `offers`/`offersStatus` pair, so the surface still has
  // exactly one offers empty/error state rather than a per-surface conditional.
  assert.match(merchant,/customerRewardOfferSwipeMarkupV339\(\{reward,items:offers,status:offersStatus/);
  assert.match(merchant,/presentation\.benefits\.length\?`<div class="customer-section-title"/);
  assert.match(merchant,/presentation\.products\.length\|\|presentation\.services\.length\?[\s\S]*customerFeatureCardMarkupV156[\s\S]*Featured services and products will appear here after this business publishes them\./);
  assert.match(wallet,/customerFeatures\.customer_birthday_benefits&&actionableCard\?\.birthday_benefit&&actionableCard\.birthday_benefit\.status!=='unavailable'/);
});

test('successful empty optional feature feeds remove sections, while featured products show an explicit empty state',()=>{
  const empty=section('async function walletSectionEmpty','function renderWalletAppointments');
  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  const merchant=section('function customerMerchantExperienceMarkupV95','function actionableWalletCardMarkup');
  assert.match(empty,/await (?:sb\.rpc|customerRpc)\('customer_portal_capabilities',\{p_business_slug:businessSlug\}\)/);
  assert.ok((empty.match(/walletSectionStillCurrent\(host,isCurrent\)/g)||[]).length>=2);
  assert.match(empty,/if\(!data\?\.\[capability\]\)\{host\.remove\(\);ensureWalletEmptyState\(businessSlug\);return\}/);
  assert.match(empty,/host\.remove\(\);ensureWalletEmptyState\(businessSlug\)/);
  assert.doesNotMatch(empty,/No rewards|No packages|No membership|No appointments/);
  assert.match(merchant,/Featured services and products will appear here after this business publishes them\./);
});

test('enabled transaction history preserves a calm explicit zero-history state',()=>{
  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  assert.match(wallet,/if\(!transactionState\.items\.length\)\{[\s\S]*No purchases or points activity has been recorded for this programme yet\./);
  assert.doesNotMatch(wallet,/id="walletTransactionsRetry"/);
  assert.doesNotMatch(wallet,/\$\('walletTransactionsRetry'\)\.onclick/);
  assert.doesNotMatch(wallet,/if\(!transactionState\.items\.length\)\{\s*host\.remove\(\)/s);
});
