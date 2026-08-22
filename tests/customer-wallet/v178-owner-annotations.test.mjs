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
  assert.match(home,/customerMyRewardsHeadingV156\(cards\.length,\{scanId:'customerHomeScan',categories:customerRewardCategoriesPresentV395\(cards\)\}\)/);
  assert.match(home,/\$\('customerHomeScan'\)\.onclick=openCustomerJoinScanner/);
  assert.match(app,/function customerMyRewardsHeadingV156\(count=0,\{scanId='',categories=\[\]\}=\{\}\)/);
  assert.match(app,/scanId\?`<button class="btn sm" id="\$\{esc\(scanId\)\}" type="button">[\s\S]{0,160}ct\('addProgramme'\)/);

  /* v333: the markup moved into a named const so a silent refresh can compare it before painting;
     the string itself, which is what this suite reads, is unchanged. */
  const legacyHome=section('const fallbackHomeMarkupV333=`${customerHomeOffersMarkupV167(offersState)}','wireCustomerHomeOffersV167(()=>renderCustomerWallet())');
  assert.doesNotMatch(legacyHome,/Each business keeps its own rewards and balances/,
    'the legacy Home page-head title block was crossed out too');
  /* v183: the owner then struck the My Rewards block off Home entirely — heading and grid live
     on the My Rewards tab only, so Home carries the jump-off instead. */
  assert.doesNotMatch(legacyHome,/customerMyRewardsHeadingV156/);
  /* v194: the owner then struck the jump-off cards too — the same two destinations are tabs on
     every customer screen, and they now carry counts. */
  assert.doesNotMatch(legacyHome,/customerHomeQuickLinksV183/);
  /* nestly_v457 re-pinned (B-REG-017, owner ruling 2026-08-22). The My Rewards badge counted
     REWARD ACCOUNTS while sitting on a tab named "Rewards", next to a greeting and cards
     talking about rewards READY — LIVE it read "Rewards 7" beside "2 rewards ready" and two
     cards each claiming 1. Bookings keeps its badge; it counts the thing its tab is named for. */
  assert.match(legacyHome,/applyCustomerNavCountsV194\(\{bookings:/);
  const programmesTab=section('async function renderCustomerProgrammes(){','const ACTIVE_CUSTOMER_BOOKING_REQUEST_STATUSES');
  assert.match(programmesTab,/customerMyRewardsHeadingV156\(cards\.length,\{scanId:'customerHomeScan',categories:customerRewardCategoriesPresentV395\(cards\)\}\)/);
  assert.match(programmesTab,/\$\('customerHomeScan'\)\.onclick=openCustomerJoinScanner/,
    'the relocated Scan to join button must stay wired on the My Rewards tab');
});

test('the offers shelf is titled Limited offers and keeps its kicker',()=>{
  assert.match(app,/<h2 id="customerHomeOffersTitle" class="customer-home-offers-title">[\s\S]{0,200}Limited offers<\/span><\/h2>/u);
  assert.doesNotMatch(app,/Worth coming back for/,'v183: the owner struck the kicker out');
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
  // v196 removed the scan-guide note; the surface flag is what this test is about.
  assert.match(programmes,/renderActionableWalletHome\(data,\{surface:'programmes',rerender:\(\)=>renderCustomerProgrammes\(\)\}\)/);
  assert.doesNotMatch(programmes,/customerHomeOffersMarkupV167|customer_get_home_offers_v167|customerHomeGuidanceV167/);
  assert.match(programmes,/customerMyRewardsHeadingV156\(cards\.length,\{scanId:'customerHomeScan',categories:customerRewardCategoriesPresentV395\(cards\)\}\)/);

  const shell=section('function renderCustomerShell','function focusCustomerRoute');
  assert.match(shell,/backHref=businessSlug\?'#\/customer\/programmes':\(backTo\|\|''\)/);
  // v340 (gap 2): unchanged for My Rewards; only the single-business profile (which now draws
  // its own inline chevron beside the business name) suppresses this one.
  assert.match(shell,/shellBackHrefV340\?`<button class="btn ghost sm" id="walletBack" aria-label="\$\{esc\(backLabel\)\}"[^`]*min-width:44px/);
  assert.match(shell,/\$\('walletBack'\)\.onclick=\(\)=>nav\(backHref\)/);

  const render=section('function renderActionableWalletHome','async function renderCustomerWallet');
  assert.match(render,/isHome=surface!=='programmes'/);
  /* v195 (owner arrow above Limited offers): the expiring-rewards glance sits ahead of the
     offers on Home only — My Rewards is still the grid alone. */
  assert.match(render,/\$\{isHome\?`\$\{customerExpiringRewardsMarkupV195\(cards\)\}\s*\n\s*\$\{customerHomeOffersMarkupV167\(offersState\)\}/);
});

test('Bookings is a three-tab client-side filter of already-fetched records',()=>{
  // v194: the owner renamed the first tab on the screenshot — "Bookings" inside a page called
  // Bookings named nothing. The three-tab shape this test protects is unchanged.
  assert.match(app,/const CUSTOMER_BOOKING_TABS_V178=\[[\s\S]{0,240}?\['bookings','Ongoing'/);
  assert.match(app,/\['cancelled','Cancelled','No cancelled bookings\.'\]/);
  assert.match(app,/\['history','History'/);
  assert.match(app,/role="tablist" aria-label="Booking status"/);
  assert.match(app,/role="tab" id="customerBookingTab-\$\{esc\(tab\)\}"/);
  assert.match(app,/aria-selected="\$\{selected\}" aria-controls="customerBookingPanel" tabindex="\$\{selected\?'0':'-1'\}"/);
  assert.match(app,/id="customerBookingPanel" role="tabpanel"/);
  assert.match(app,/event\.key==='ArrowRight'\?1:event\.key==='ArrowLeft'\?-1:0/,'tabs must be keyboard reachable');
  assert.match(app,/\.customer-booking-tab\{[^}]*min-height:44px/,'tab targets must be at least 44px');
  /* 2026-08-20 contrast correction: --coral on --tint measured 3.94:1. The selected tab keeps
     its pink ground and moves to the --brand-red-on-soft step (5.43:1). Lock moved, not weakened. */
  assert.match(app,/\.customer-booking-tab\[aria-selected="true"\]\{background:var\(--tint\);color:var\(--brand-red-on-soft\)\}/);
  assert.match(app,/\.customer-inbox-bell,\.customer-programme-card,\.customer-booking-business,\.customer-booking-tabs,/,
    'the tab strip must join the customer dark token remap');
  // Classification, grouping and Book again all survive the restructure.
  assert.match(app,/function customerBookingRequestTabV178/);
  assert.match(app,/function customerBookingAppointmentTabV178/);
  assert.match(app,/function customerBookingTabGroupsV178/);
  assert.match(app,/data-repeat-booking data-business-slug/);
  const bookings=section('async function renderCustomerBookings(){','async function renderCustomerMessages(){');
  assert.match(bookings,/customerBookingTabGroupsV178\(allGroups,currentBookingTab,currentBookingRange\)/);
  assert.doesNotMatch(bookings,/sb\.rpc\('customer_get_booking_tab/,'tabs must not add new RPCs');
  /* v195 (owner: "put filter time here"): the time window is the same client-side filter over the
     same fetched records — it narrows what a tab shows, it never asks the server again. */
  assert.match(app,/customerBookingTabGroupsV178\(allGroups,currentBookingTab,currentBookingRange\)/);
  assert.match(app,/function customerBookingWithinRangeV196/);
  assert.doesNotMatch(bookings,/sb\.rpc\('customer_get_booking_requests',\{p_limit:50,p_cursor:null\}\)[\s\S]{0,200}windowKey/);
});

test('offer details open a company sheet with contact, current offers and a per-offer reopen',()=>{
  assert.match(app,/function customerCompanyDetailRowV178/);
  /* v195 (owner: "→ address phone number", "click here straightaway go company profile"): the row
     shows the branch address and phone once they load, and its label now says where it goes. */
  assert.match(app,/data-company-detail aria-label="Open the company profile for \$\{esc\(name\)\}"/);
  assert.match(app,/<span class="muted small" data-company-row-lines>\$\{lines\|\|'Company profile'\}<\/span>/);
  assert.match(app,/const summary=\[branch\.address,branch\.phone\]/);
  assert.match(app,/\.customer-company-row,\.customer-business-offer\{[^}]*min-height:52px/);
  /* v326 (owner: "when I click this, straightaway go to company profile inside, don't need
     another pop-out"): this specific company row — inside showCustomerOfferDetailV173 — now
     navigates straight to the business's own programme page instead of opening this sheet.
     showCustomerBusinessDetailV178 itself is untouched and still opened elsewhere (the header's
     own [data-company-detail] wiring), which the rest of this test still covers below. */
  assert.match(app,/companyButton\.onclick=\(\)=>\{[\s\S]{0,260}const target=`#\/wallet\/\$\{encodeURIComponent\(business\.slug\|\|''\)\}`/);

  const sheet=section('function showCustomerBusinessDetailV178','function showCustomerOfferDetailV173');
  assert.match(sheet,/overlay\.className='modal customer-surface customer-business-detail-modal'/);
  assert.match(sheet,/CUI\.activateDialog\(overlay,\{onClose:\(\)=>deactivate\(\{restoreFocus:true\}\),initialFocus:'#customerBusinessDetailClose',inheritHistoryId\}\)/);
  assert.match(sheet,/customerCompanyIdentityMarkupV178\(business\)/);
  assert.match(sheet,/customerRpc\('customer_get_offer_business_contact_v173',\{p_business:business\.id\}\)/);
  assert.match(sheet,/Loading contact details…/);
  assert.match(sheet,/Contact details unavailable\./);
  assert.match(sheet,/href="tel:/);
  assert.match(sheet,/href="mailto:/);
  /* v386 (owner photo 2, both scribbled out): the sheet no longer lists "Current offers" — the
     programme page behind it already shows them — and no longer carries an "Open <business>
     rewards" button that navigated to the page the customer was already on. It gained the phone
     glyph beside the number, and every other branch under the default one. */
  assert.doesNotMatch(sheet,/customer_get_promotions_v155/,'no second offers read from the company sheet');
  assert.doesNotMatch(sheet,/Current offers/);
  assert.doesNotMatch(sheet,/ct\('openProgramme',\{business:name\}\)/);
  assert.doesNotMatch(sheet,/data-business-detail-nav/);
  assert.match(sheet,/customerBranchContactLinesV386\(branch\)/);
  assert.match(sheet,/data-business-branches-v386/);
  assert.match(app,/function customerBranchContactLinesV386[\s\S]{0,900}CUI\.icon\('phone',\{size:16\}\)/,
    'the phone number carries a phone glyph, which is what the owner drew');
  assert.match(app,/function customerCompanyIdentityMarkupV178[\s\S]{0,400}customerMediaUrlV95\(business\?\.logo_url\)/);
  assert.match(app,/\.customer-business-detail-modal \.modal-card\{width:min\(var\(--dialog-w-md\)/);
});

test('the header notification bell is gated on customer_in_app_inbox and links to the messages history',()=>{
  const shell=section('function renderCustomerShell','function focusCustomerRoute');
  assert.match(shell,/inboxAvailable=messagesAvailable===null\?customerInboxEnabledV178===true:messagesAvailable===true/);
  /* nestly_v397 (owner photo A: an arrow up at the bell, "default page got this"). The bell is
     the door TO Messages — on Messages itself it navigates nowhere and counts what is already on
     screen. Still gated on the same feature flag; the gate simply also excludes its own page. */
  assert.match(shell,/const inboxBellVisibleV397=inboxAvailable&&active!=='messages';/);
  assert.match(shell,/inboxBellVisibleV397\?`<a class="customer-inbox-bell" href="#\/customer\/messages"/);
  assert.match(shell,/id="customerInboxBellSlot"\$\{compactBusinessHeadV339\|\|!inboxBellVisibleV397\?' hidden':''\}/,
    'and the empty slot is hidden with it, so it cannot hold layout open');
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
