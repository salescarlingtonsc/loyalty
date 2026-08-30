import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../../',import.meta.url);
const app=((await readFile(new URL('app/index.html',root),'utf8'))+'\n'+(await readFile(new URL('app/app.js',root),'utf8')));
const brand=await readFile(new URL('app/brand-config.js',root),'utf8');
const manifest=JSON.parse(await readFile(new URL('app/manifest.webmanifest',root),'utf8'));
const vercel=JSON.parse(await readFile(new URL('app/vercel.json',root),'utf8'));
const vercelTemplate=JSON.parse(await readFile(new URL('config/runtime/vercel.template.json',root),'utf8'));
const entryRoutingDoc=await readFile(new URL('docs/release/entry-routing-and-super-admin-login.md',root),'utf8');

const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.notEqual(from,-1,`missing section ${start}`);
  assert.notEqual(to,-1,`missing section boundary ${end}`);
  return app.slice(from,to);
};

test('root is customer-first and business sign-in is a separate clean entry path',()=>{
  assert.match(brand,/productName:\s*'Peekaa'/);
  assert.match(brand,/customerLabel:\s*'My Peekaa'/);
  const entry=section('function customerRegistrationShell(body)','function renderCustomerOtpVerification');
  assert.match(entry,/class="customer-entry-footer"/);
  assert.match(entry,/class="customer-business-link" href="\/business">Business sign in<\/a>/);
  assert.doesNotMatch(entry,/Choose account type|id="customerBack"/);

  const auth=section("function renderAuth(mode='in',{admin=false}={})",'function validNewPassword');
  assert.match(auth,/class="entry-path-switch" aria-label="Account type"/);
  assert.match(auth,/href="\/business" aria-current="page"/);
  /* V274: bare "/" serves the marketing landing now, so the customer-app link says /app. */
  assert.match(auth,/href="\/app"/);
  assert.match(auth,/<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="businessAuthTitle">/);
  assert.match(auth,/<h1 id="businessAuthTitle"[^>]*>\$\{admin\?'Super admin sign in':mode==='in'\?'Sign in':'Create your account'\}<\/h1>/);

  const routing=section('function entryRouteForLocation','/* ---------- customer wallet ---------- */');
  assert.match(routing,/if\(cleanPath==='\/business'\)return '#\/business'/);
  assert.match(routing,/if\(h==='#\/'\|\|h==='#\/customer'/);
  assert.match(routing,/if\(!S\.user\)return renderAuth\('in',\{admin:/);
  assert.doesNotMatch(app,/function renderEntryChoice\(/);

  /* V274: the Customer home shortcut says /app for the same reason as the links above. */
  assert.deepEqual(manifest.shortcuts.map(({url})=>url),['/app','/business']);
  /* V274: "/" now serves the marketing landing page. The app keeps every entry it had —
     installed PWAs via the ?source=pwa guard, and everyone else via /app, which
     entryRouteForLocation resolves to '#/' exactly as bare "/" used to. */
  /* V274 follow-up: the first deploy proved a "/" rewrite can never fire — Vercel resolves the
     filesystem before rewrites, and index.html always won. "/" is owned by app/middleware.js
     (edge middleware runs before the filesystem), which falls OPEN to the app on any failure.
     The two dead "/" rewrites are gone rather than left as misleading config. */
  const expectedRewrites=[
    /* nestly_v527: these three now serve index.gen.html — the same document with its 512KB
       inline stylesheet swapped for a fingerprinted <link href="/app.css">. app/index.html is
       still the source this very file reads on line 6; only what customers download changed. */
    {source:'/app',destination:'/index.gen.html'},
    /* nestly_v606: the counter QR lands on /join — a small standalone page that paints
       "Join <business>?" immediately, before the SPA is involved at all. */
    {source:'/join',destination:'/join.html'},
    /* v268: /o/<offer-id> is the server-rendered shared-offer page — the ONE route that must
       NOT fall through to the SPA shell, because link-preview crawlers never run JavaScript
       and can only read tags a server actually sent. */
    {source:'/o/:id',destination:'/api/offer-share?id=:id'},
    {source:'/business',destination:'/index.gen.html'},
    {source:'/admin',destination:'/index.gen.html'}
  ];
  assert.deepEqual(vercel.rewrites,expectedRewrites);
  assert.deepEqual(vercelTemplate.rewrites,expectedRewrites);
});

test('business entry resolves workspaces while customer and workspace deep links remain authoritative',()=>{
  const routing=section('async function route()','/* ---------- customer wallet ---------- */');
  assert.match(routing,/if\(h==='#\/business'\)\{/);
  assert.match(routing,/if\(staff\.length>1\)return renderPersonaChoice\(businessPersonas,\{includeCustomer:false\}\)/);
  assert.match(routing,/preferredRoute\.startsWith\('#\/workspace\/'\)\?preferredRoute:workspaceRoute/);
  assert.match(routing,/if\(h==='#\/wallet'\|\|h\.startsWith\('#\/wallet\/'\)\)/);
  assert.match(routing,/if\(h\.startsWith\('#\/workspace\/'\)\)/);

  const chooser=section('function renderPersonaChoice(personas,{includeCustomer=true}={})','function renderAuth');
  assert.match(chooser,/const hasCustomer=includeCustomer&&/);
  assert.match(chooser,/<h2 id="personaWorkspacesTitle">Business workspaces<\/h2>/);
  assert.match(chooser,/<h2>\$\{esc\(BRAND\.customerLabel\)\}<\/h2>/);
  assert.match(chooser,/staff\.map\(workspace=>`<a class="btn ghost" href="#\/workspace\/\$\{encodeURIComponent\(workspace\.business_slug\)\}\/dashboard"/);
  assert.match(chooser,/href="#\/wallet"/);
});

test('hidden admin entry uses normal auth and resolves Platform before tenant discovery',()=>{
  const routing=section('function entryRouteForLocation','/* ---------- customer wallet ---------- */');
  assert.match(routing,/if\(cleanPath==='\/admin'\)return '#\/platform'/);
  assert.match(routing,/const platformRoutePath=String\(h\)\.split\('\?'\)\[0\]\.replace\(\/\\\/\+\$\/,''\)/);
  assert.match(routing,/const requestedPlatformRoute=platformRoutePath==='#\/platform'\|\|platformRoutePath\.startsWith\('#\/platform\/'\)/);
  assert.match(routing,/renderAuth\('in',\{admin:requestedPlatformRoute\}\)/);
  const platformAt=routing.indexOf('if(requestedPlatformRoute)');
  const businessAt=routing.indexOf("if(h==='#/business')");
  const discoveryAt=routing.indexOf("if(h.startsWith('#/workspace/'))");
  assert.ok(platformAt>=0&&businessAt>platformAt&&discoveryAt>businessAt,
    'Platform must resolve before business workspace discovery or onboarding');
  assert.doesNotMatch(app,/<a[^>]+href="\/admin"/);
  const auth=section("function renderAuth(mode='in',{admin=false}={})",'function validNewPassword');
  assert.match(auth,/admin\?'Super admin sign in'/);
  assert.match(auth,/admin\?'':`<nav class="entry-path-switch"/);
  /* nestly_v627: v625 gave renderAuth one admin arm and one business arm, so the mode switcher is
     no longer guarded by its own `admin?'':` ternary — it lives in the business arm. The property
     this line has always been protecting is that a super admin gets no sign-up switcher, and that
     is what it checks now. */
  const adminArm=auth.slice(
    auth.indexOf("${admin?`${businessGoogleButtonHtml('platformGoogleSignIn')"),
    auth.indexOf("${!NestlyNativeBridge.isNative?`${businessGoogleButtonHtml('businessGoogleSignIn')"));
  assert.ok(adminArm.length>40,'the admin arm of renderAuth must be locatable');
  assert.doesNotMatch(adminArm,/id="sw"/,'a super admin has no account to sign up for');
  assert.match(auth,/<span class="spacer"><\/span><button class="btn ghost sm" id="sw"/);
  assert.match(entryRoutingDoc,/uses the normal business email\/password authentication method/);
  assert.match(entryRoutingDoc,/does not create an Auth user/);
});

test('customer secondary routes are namespaced and cannot intercept merchant Bookings',()=>{
  const routing=section('async function route()','/* ---------- customer wallet ---------- */');
  assert.match(routing,/h==='#\/customer\/programmes'\)return renderCustomerProgrammes\(\)/);
  assert.match(routing,/h==='#\/customer\/bookings'\)return renderCustomerBookings\(\)/);
  assert.match(routing,/h==='#\/customer\/messages'\)return renderCustomerMessages\(\)/);
  assert.match(routing,/h==='#\/customer\/profile'\)return renderCustomerProfile\(\)/);
  assert.doesNotMatch(routing,/h==='#\/bookings'\)return renderCustomerBookings\(\)/);
  assert.match(app,/const NOTIF_ROUTE=\{booking_new:'#\/bookings'/);
});

test('customer navigation keeps destinations focused while notifications and profile live in the header',()=>{
  const nav=section('const CUSTOMER_PRIMARY_NAV=Object.freeze([','function customerPrimaryNavigation(');
  /* v244 (owner's Grab-style reference): Scan is the raised centre action — a BUTTON, not a
     route, so it still cannot intercept merchant navigation, and it stays wired through the same
     id on every page. v248 hid Explore behind CUSTOMER_EXPLORE_LIVE_V248; v393 removed the
     destination outright on the owner's decision, so the nav declares exactly five slots and the
     conditional entry is gone with the page it pointed at. */
  assert.equal((nav.match(/\{key:/g)||[]).length,5);
  assert.doesNotMatch(nav,/key:'explore'/,'Explore is removed, not conditional');
  for(const [key,href,copy] of [
    ['home','#/wallet','home'],
    ['programmes','#/customer/programmes','rewardsTab'],
    ['bookings','#/customer/bookings','bookings'],
    /* v281 (owner): Profile promoted from the header avatar menu to the rightmost slot */
    ['profile','#/customer/profile','profileTab']
  ]){
    assert.match(nav,new RegExp(`key:'${key}',href:'${href.replaceAll('/','\\/')}'[^\\n]*copy:'${copy}'`));
  }
  assert.match(nav,/\{key:'scan',icon:'scan',copy:'scanQr'\}/);
  assert.match(app,/id="customerNavScan" class="customer-nav-scan"/);
  assert.match(app,/if\(\$\('customerNavScan'\)\)\$\('customerNavScan'\)\.onclick=openCustomerJoinScanner/);
  assert.doesNotMatch(nav,/key:'messages'/);
  const navMarkup=section('function customerPrimaryNavigation(active','function renderCustomerShell');
  assert.match(navMarkup,/<nav class="customer-primary-nav" aria-label="\$\{esc\(BRAND\.customerLabel\)\}">/);
  assert.match(navMarkup,/aria-current="page"/);
  assert.match(navMarkup,/CUI\.icon\(item\.icon/);
  assert.match(navMarkup,/<span>\$\{esc\(ct\(item\.copy\)\)\}<\/span>/);

  assert.match(app,/\.customer-primary-nav\{[^}]*grid-template-columns:1fr 1fr auto 1fr 1fr;/s,
    'five slots while Explore is hidden: Home, Rewards, Scan, Bookings, Profile');
  assert.match(app,/\.customer-primary-nav a,\.customer-primary-nav button:not\(\.customer-nav-scan\)\{[^}]*min-height:48px/s);
  assert.match(app,/@media\(max-width:720px\)\{[\s\S]*\.customer-primary-nav\{position:fixed[^}]*bottom:/);
});

test('customer shell, deep links, and profile transitions are predictable and accessible',()=>{
  const shell=section('function renderCustomerShell','function focusCustomerRoute');
  assert.match(shell,/<a class="logo" href="#\/wallet" aria-label="\$\{esc\(BRAND\.customerLabel\)\} home"/);
  assert.match(shell,/<main id="main" tabindex="-1">/);
  assert.match(shell,/customerWorkspaceSwitchHtml\(staffWorkspaces\)/);
  /* v296 (owner: "remove this — here got profile already"): the avatar menu is gone. Profile is
     a nav tab, device notifications sit with the inbox they govern, and Sign out is the last
     card on Profile. The header must never grow a second door to any of them again. */
  assert.doesNotMatch(shell,/customer-account-menu|customer-avatar/);
  assert.doesNotMatch(shell,/id="walletSignOut"|customerPushMenuControl/);
  assert.doesNotMatch(shell,/href="#\/customer\/profile"/);
  assert.match(shell,/href="#\/customer\/messages" aria-label="\$\{esc\(ct\('notifications'\)\)\}"/);
  // v178: the back control is now generic — a business page returns to My Rewards, and My
  // Rewards itself passes backTo:'#/wallet' (the owner: "There is no back button").
  assert.match(shell,/backHref=businessSlug\?'#\/customer\/programmes':\(backTo\|\|''\)/);
  assert.match(shell,/walletBack'\)\.onclick=\(\)=>nav\(backHref\)/);
  /* v340 (gap 2): on the collapsed business profile the chevron moved into the business
     header itself (customerMerchantExperienceMarkupV95), so the shell suppresses its own copy
     there and nowhere else — shellBackHrefV340 is the only thing between backHref and the
     button, and every non-profile surface still draws it exactly as before. */
  assert.match(shell,/const shellBackHrefV340=compactBusinessHeadV339\?'':backHref;/);
  assert.match(shell,/shellBackHrefV340\?`<button class="btn ghost sm" id="walletBack"/);
  assert.doesNotMatch(shell,/history\.back/);
  assert.match(app,/function focusCustomerRoute\(\)\{[\s\S]*CUI\.focusRoute\(main,\{enhanceContent:true\}\)/);

  const context=section('async function loadCustomerSurfaceContext','async function renderCustomerProgrammes');
  assert.match(context,/customerSurfaceQualifies\(profile,customer\)/);
  assert.match(context,/renderNoCustomerDestination\(staff\)/);
  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  assert.match(wallet,/loadCustomerSurfaceContext\(isWalletCurrent,\{silent\}\)/);
});

test('customer home and destinations reuse existing customer contracts with honest unavailable states',()=>{
  const surfaces=section('async function loadCustomerSurfaceContext','async function renderCustomerClaim');
  for(const rpc of [
    'customer_get_actionable_wallet',
    'customer_get_wallet',
    'customer_get_appointments_page',
    'customer_get_profile',
    'customer_update_profile'
  ])assert.match(surfaces,new RegExp(`(?:sb\\.rpc|customerRpc)\\('${rpc}'`));
  assert.match(surfaces,/p_cursor:\{limit:20\}/);
  assert.match(surfaces,/renderCustomerWalletRetry\('Your rewards are temporarily unavailable\.',null,\(\)=>renderCustomerProgrammes\(\),error\)/);
  assert.match(surfaces,/Your booking requests and appointments are temporarily unavailable/);
  /* v196 (owner struck the card out): the "Joining a new rewards account" explainer is gone from
     My Rewards — a page listing the customer's own reward accounts was explaining how to get one.
     The QR-only rule still reaches the customer who has none, through the first-programme quest. */
  assert.doesNotMatch(surfaces,/<b>Joining a new rewards account<\/b>/);
  assert.match(app,/function renderCustomerFirstProgrammeQuest/);
  assert.match(surfaces,/if\(!cards\.length\)\{renderCustomerFirstProgrammeQuest\(\);return\}/);
  assert.doesNotMatch(surfaces,/href="#\/claim"/);
  /* v194 (owner struck the subtitle out on the screenshot): the tabs are self-describing, so the
     sentence that repeated them is gone. The tablist itself is what must survive, asserted below. */
  assert.doesNotMatch(surfaces,/Active requests and appointments, cancellations and past visits stay in separate tabs/);
  // v178 (owner sketch): Bookings | Cancelled | History, filtered client-side.
  assert.match(surfaces,/role="tablist" aria-label="Booking status"/);
  assert.match(surfaces,/renderCustomerShell\(\{active:'programmes',backTo:'#\/wallet'/);
  assert.match(surfaces,/if\(context\.features\.customer_in_app_inbox!==true\)\{[\s\S]*Messages are not available[\s\S]*This feature is not available for your account right now/,
    'a manually entered disabled Messages destination must remain visible with an honest unavailable state');
  assert.match(surfaces,/await renderCustomerInAppInbox\(null,isCurrent\)/,
    'an enabled Messages destination must render the existing customer inbox rather than placeholder copy');
  assert.match(surfaces,/Profile editing is not available/);
  assert.match(surfaces,/Date of birth/);
  assert.match(surfaces,/not editable here/);

  // v178: the owner crossed out the Home page-head title block. "Scan to join" moved into the
  // My Rewards section heading row, and the only surviving guidance is a pending redemption.
  const home=section('function customerMyRewardsHeadingV156','async function renderCustomerWallet');
  assert.doesNotMatch(home,/ct\('chooseProgramme'\)|ct\('programmesIntro'\)/);
  assert.match(home,/id="\$\{esc\(scanId\)\}"/);
  assert.match(home,/ct\('addProgramme'\)/);
  assert.match(home,/customerMyRewardsHeadingV156\(cards\.length,\{scanId:'customerHomeScan',categories:customerRewardCategoriesPresentV395\(cards\)\}\)/);
  assert.match(home,/if\(!cards\.length\)\{[\s\S]*customer-first-quest/,
    'an empty actionable wallet must retain the first-programme QR journey inline');
  assert.match(home,/customerHomeGuidanceV167\(\{pendingRedemption,actionableCards:cards,legacyCards,offers:offersState\.items\}\)/,
    'Home guidance must use the canonical V167 fallback renderer');
  assert.match(home,/Next best action/);
  assert.match(home,/Complete your pending redemption/);
  assert.doesNotMatch(home,/No urgent action is available right now/);
  assert.doesNotMatch(home,/href="#\/claim"/);

  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  assert.match(wallet,/const context=await loadCustomerSurfaceContext\(isWalletCurrent,\{silent\}\)/);
  /* v286: the ordering invariant is unchanged (sync, then count); the calls moved onto customerRpc
     so they inherit the v177 abort deadline instead of hanging Home forever. */
  const syncAt=wallet.indexOf("customerRpc('customer_sync_in_app_inbox_global'");
  const countAt=wallet.indexOf("return customerRpc('customer_get_in_app_inbox_global_count')");
  assert.ok(syncAt>=0&&countAt>syncAt,'home must sync the global inbox before claiming a current unread count');
  assert.match(wallet,/claimsAvailable:false/);
  assert.match(wallet,/customer_create_redemption_intent_v89/);
  assert.match(wallet,/intent\?\.status!=='pending'\|\|!intent\?\.qr_token/);
});
