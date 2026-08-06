import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

/* v178 — owner iPad annotations on the customer surface.
   Tests read the concatenation of app/index.html (markup + CSS) and app/app.js (behaviour). */
const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))
  +'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
};

test('Home drops the crossed-out page-head title block and keeps Scan to join in the My Rewards heading',()=>{
  const home=section('function customerMyRewardsHeadingV156','async function renderCustomerWallet');
  assert.doesNotMatch(home,/ct\('chooseProgramme'\)/,'the "Choose a reward business" kicker was crossed out');
  assert.doesNotMatch(home,/ct\('programmesIntro'\)/,'the "Pick a business to open its rewards…" line was crossed out');
  assert.match(home,/customerMyRewardsHeadingV156\(cards\.length,\{scanId:'customerHomeScan'\}\)/);
  assert.match(home,/\$\('customerHomeScan'\)\.onclick=openCustomerJoinScanner/);
  assert.match(app,/function customerMyRewardsHeadingV156\(count=0,\{scanId=''\}=\{\}\)/);
  assert.match(app,/scanId\?`<button class="btn sm" id="\$\{esc\(scanId\)\}" type="button">[\s\S]{0,160}ct\('addProgramme'\)/);

  const legacyHome=section("$('walletBody').innerHTML=`${customerHomeOffersMarkupV167(offersState)}",'wireCustomerHomeOffersV167(()=>renderCustomerWallet())');
  assert.doesNotMatch(legacyHome,/Each business keeps its own rewards and balances/,
    'the legacy Home page-head title block was crossed out too');
  assert.match(legacyHome,/customerMyRewardsHeadingV156\(cards\.length,\{scanId:'customerHomeScan'\}\)/);
  assert.match(legacyHome,/if\(\$\('customerHomeScan'\)\)\$\('customerHomeScan'\)\.onclick=openCustomerJoinScanner/,
    'the relocated Scan to join button must be wired on the legacy Home path too');
});

test('the offers shelf is titled Limited offers and keeps its kicker',()=>{
  assert.match(app,/<p class="customer-quest-kicker">Worth coming back for<\/p><h2 id="customerHomeOffersTitle">Limited offers<\/h2>/);
  assert.doesNotMatch(app,/Offers for you/);
});

test('Home keeps only the pending-redemption next-best-action variant',()=>{
  const guidance=section('function customerHomeFallbackActionV167','function renderActionableWalletHome');
  assert.match(guidance,/if\(!pendingRedemption\)return ''/);
  assert.match(guidance,/Complete your pending redemption/);
  assert.doesNotMatch(guidance,/available_now|sessions_remaining|upcoming_appointments/,
    'reward-ready, package and appointment banners were crossed out');
  assert.doesNotMatch(app,/function customerHomeNextActionMarkup/);
  assert.doesNotMatch(app,/Use your ready reward|Use an active package session|Check your upcoming booking/);
  assert.match(app,/function customerHomeGuidanceV167\(\{pendingRedemption=null,actionableCards=\[\],legacyCards=\[\],offers=\[\]\}=\{\}\)\{\s*return customerHomeFallbackActionV167/);
  // Reward readiness still reads on the wallet card itself, so nothing is lost by removing the banner.
  assert.match(app,/is ready to redeem/);
});

test('My Rewards has a back button and no offers shelf or guidance banner',()=>{
  const programmes=section('async function renderCustomerProgrammes','const ACTIVE_CUSTOMER_BOOKING_REQUEST_STATUSES');
  assert.match(programmes,/renderCustomerShell\(\{active:'programmes',backTo:'#\/wallet'/);
  assert.match(programmes,/renderActionableWalletHome\(data,\{surface:'programmes',note:scanGuide,rerender:\(\)=>renderCustomerProgrammes\(\)\}\)/);
  assert.doesNotMatch(programmes,/customerHomeOffersMarkupV167|customer_get_home_offers_v167|customerHomeGuidanceV167/);
  assert.match(programmes,/customerMyRewardsHeadingV156\(cards\.length,\{scanId:'customerHomeScan'\}\)/);

  const shell=section('function renderCustomerShell','function focusCustomerRoute');
  assert.match(shell,/backHref=businessSlug\?'#\/customer\/programmes':\(backTo\|\|''\)/);
  assert.match(shell,/backHref\?`<button class="btn ghost sm" id="walletBack" aria-label="\$\{esc\(backLabel\)\}"[^`]*min-width:44px/);
  assert.match(shell,/\$\('walletBack'\)\.onclick=\(\)=>nav\(backHref\)/);

  const render=section('function renderActionableWalletHome','async function renderCustomerWallet');
  assert.match(render,/isHome=surface!=='programmes'/);
  assert.match(render,/\$\{isHome\?`\$\{customerHomeOffersMarkupV167\(offersState\)\}/);
});

test('Bookings is a three-tab client-side filter of already-fetched records',()=>{
  assert.match(app,/const CUSTOMER_BOOKING_TABS_V178=\[\s*\['bookings','Bookings'/);
  assert.match(app,/\['cancelled','Cancelled','No cancelled bookings\.'\]/);
  assert.match(app,/\['history','History'/);
  assert.match(app,/role="tablist" aria-label="Booking status"/);
  assert.match(app,/role="tab" id="customerBookingTab-\$\{esc\(tab\)\}"/);
  assert.match(app,/aria-selected="\$\{selected\}" aria-controls="customerBookingPanel" tabindex="\$\{selected\?'0':'-1'\}"/);
  assert.match(app,/id="customerBookingPanel" role="tabpanel"/);
  assert.match(app,/event\.key==='ArrowRight'\?1:event\.key==='ArrowLeft'\?-1:0/,'tabs must be keyboard reachable');
  assert.match(app,/\.customer-booking-tab\{[^}]*min-height:44px/,'tab targets must be at least 44px');
  assert.match(app,/\.customer-booking-tab\[aria-selected="true"\]\{background:var\(--tint\);color:var\(--coral\)\}/);
  assert.match(app,/\.customer-inbox-bell,\.customer-programme-card,\.customer-booking-business,\.customer-booking-tabs,/,
    'the tab strip must join the customer dark token remap');
  // Classification, grouping and Book again all survive the restructure.
  assert.match(app,/function customerBookingRequestTabV178/);
  assert.match(app,/function customerBookingAppointmentTabV178/);
  assert.match(app,/function customerBookingTabGroupsV178/);
  assert.match(app,/data-repeat-booking data-business-slug/);
  const bookings=section('async function renderCustomerBookings(){','async function renderCustomerMessages(){');
  assert.match(bookings,/customerBookingTabGroupsV178\(allGroups,currentBookingTab\)/);
  assert.doesNotMatch(bookings,/sb\.rpc\('customer_get_booking_tab/,'tabs must not add new RPCs');
});

test('offer details open a company sheet with contact, current offers and a per-offer reopen',()=>{
  assert.match(app,/function customerCompanyDetailRowV178/);
  assert.match(app,/data-company-detail aria-label="Company details for \$\{esc\(name\)\}"/);
  assert.match(app,/<span class="muted small">Company details<\/span>/);
  assert.match(app,/\.customer-company-row,\.customer-business-offer\{[^}]*min-height:52px/);
  assert.match(app,/companyButton\.onclick=\(\)=>\{deactivate\(\{restoreFocus:false\}\);showCustomerBusinessDetailV178\(business\)\}/);

  const sheet=section('function showCustomerBusinessDetailV178','function showCustomerOfferDetailV173');
  assert.match(sheet,/overlay\.className='modal customer-surface customer-business-detail-modal'/);
  assert.match(sheet,/CUI\.activateDialog\(overlay,\{onClose:\(\)=>deactivate\(\{restoreFocus:true\}\),initialFocus:'#customerBusinessDetailClose'\}\)/);
  assert.match(sheet,/customerCompanyIdentityMarkupV178\(business\)/);
  assert.match(sheet,/customerRpc\('customer_get_offer_business_contact_v173',\{p_business:business\.id\}\)/);
  assert.match(sheet,/Loading contact details…/);
  assert.match(sheet,/Contact details unavailable\./);
  assert.match(sheet,/href="tel:/);
  assert.match(sheet,/href="mailto:/);
  assert.match(sheet,/customerRpc\('customer_get_promotions_v155',\{p_business:business\.id,p_branch:null,p_locale:'en'\}\)/);
  assert.match(sheet,/Loading offers…/);
  assert.match(sheet,/No current offers from this business\./);
  assert.match(sheet,/Current offers couldn’t load\./);
  assert.match(sheet,/deactivate\(\{restoreFocus:false\}\);\s*showCustomerOfferDetailV173\(\{\.\.\.offer,business:\{\.\.\.business,\.\.\.\(offer\.business\|\|\{\}\)\}\}\)/);
  assert.match(sheet,/ct\('openProgramme',\{business:name\}\)/);
  assert.match(sheet,/href="#\/wallet\/\$\{slug\}" data-business-detail-nav/);
  assert.match(app,/function customerCompanyIdentityMarkupV178[\s\S]{0,400}customerMediaUrlV95\(business\?\.logo_url\)/);
  assert.match(app,/\.customer-business-detail-modal \.modal-card\{width:min\(480px/);
});

test('the header notification bell is gated on customer_in_app_inbox and links to the messages history',()=>{
  const shell=section('function renderCustomerShell','function focusCustomerRoute');
  assert.match(shell,/inboxAvailable=messagesAvailable===null\?customerInboxEnabledV178===true:messagesAvailable===true/);
  assert.match(shell,/inboxAvailable\?`<a class="customer-inbox-bell" href="#\/customer\/messages"/);
  assert.match(app,/customerInboxEnabledV178=features\?\.customer_in_app_inbox===true/);
  // Off by default, so the bell is absent until the platform flag is enabled.
  assert.match(app,/let customerInboxEnabledV178=false/);
  assert.match(app,/customer_in_app_inbox:false/);
  // Unread badge where a count is available.
  assert.match(app,/customer-inbox-badge" aria-hidden="true">\$\{unread>99\?'99\+':unread\}/);
  // The messages page defaults to every item, not just unread, so read items read as history.
  const inbox=section('async function renderCustomerInAppInbox','const setState=async(item,operation)=>');
  assert.match(inbox,/let currentFilter='all'/);
  assert.match(inbox,/isResolved\?'Resolved history':isUnavailable\?'Programme temporarily unavailable':state==='unread'\?'Unread':'Read'/);
  assert.match(inbox,/data-inbox-filter="all"/);
});
