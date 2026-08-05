import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../../',import.meta.url);
const app=await readFile(new URL('app/index.html',root),'utf8');
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
  assert.match(auth,/href="\/"/);
  assert.match(auth,/<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="businessAuthTitle">/);
  assert.match(auth,/<h1 id="businessAuthTitle"[^>]*>\$\{admin\?'Super admin sign in':mode==='in'\?'Sign in':'Create your account'\}<\/h1>/);

  const routing=section('function entryRouteForLocation','/* ---------- customer wallet ---------- */');
  assert.match(routing,/if\(cleanPath==='\/business'\)return '#\/business'/);
  assert.match(routing,/if\(h==='#\/'\|\|h==='#\/customer'/);
  assert.match(routing,/if\(!S\.user\)return renderAuth\('in',\{admin:/);
  assert.doesNotMatch(app,/function renderEntryChoice\(/);

  assert.deepEqual(manifest.shortcuts.map(({url})=>url),['/','/business']);
  const expectedRewrites=[
    {source:'/business',destination:'/index.html'},
    {source:'/admin',destination:'/index.html'}
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
  assert.match(chooser,/staff\.map\(workspace=>`<a class="btn ghost sm" href="#\/workspace\/\$\{encodeURIComponent\(workspace\.business_slug\)\}\/dashboard"/);
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
  assert.match(auth,/admin\?'':`<span class="spacer"><\/span><button class="btn ghost sm" id="sw"/);
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
  const nav=section('const CUSTOMER_PRIMARY_NAV=Object.freeze([',']);\nfunction customerPrimaryNavigation');
  assert.equal((nav.match(/\{key:/g)||[]).length,4);
  for(const [key,href,copy] of [
    ['home','#/wallet','home'],
    ['programmes','#/customer/programmes','programmes'],
    ['bookings','#/customer/bookings','bookings']
  ]){
    assert.match(nav,new RegExp(`key:'${key}',href:'${href.replaceAll('/','\\/')}'[^\\n]*copy:'${copy}'`));
  }
  assert.match(nav,/key:'scan',icon:'scan',copy:'scanQr'/);
  assert.doesNotMatch(nav,/key:'messages'|key:'profile'/);
  const navMarkup=section('function customerPrimaryNavigation(active)','function renderCustomerShell');
  assert.match(navMarkup,/<nav class="customer-primary-nav" aria-label="\$\{esc\(BRAND\.customerLabel\)\}">/);
  assert.match(navMarkup,/aria-current="page"/);
  assert.match(navMarkup,/CUI\.icon\(item\.icon/);
  assert.match(navMarkup,/<span>\$\{esc\(ct\(item\.copy\)\)\}<\/span>/);

  assert.match(app,/\.customer-primary-nav\{[^}]*grid-template-columns:repeat\(4,minmax\(0,1fr\)\)/s);
  assert.match(app,/\.customer-primary-nav a,\.customer-primary-nav button\{[^}]*min-height:48px/s);
  assert.match(app,/@media\(max-width:720px\)\{[\s\S]*\.customer-primary-nav\{position:fixed[^}]*bottom:/);
});

test('customer shell, deep links, and profile transitions are predictable and accessible',()=>{
  const shell=section('function renderCustomerShell','function focusCustomerRoute');
  assert.match(shell,/<a class="logo" href="#\/wallet" aria-label="\$\{esc\(BRAND\.customerLabel\)\} home"/);
  assert.match(shell,/<main id="main" tabindex="-1">/);
  assert.match(shell,/customerWorkspaceSwitchHtml\(staffWorkspaces\)/);
  assert.match(shell,/class="customer-account-menu"/);
  assert.match(shell,/href="#\/customer\/profile"/);
  assert.match(shell,/id="walletSignOut"/);
  assert.match(shell,/href="#\/customer\/messages" aria-label="\$\{esc\(ct\('notifications'\)\)\}"/);
  assert.match(shell,/walletBack'\)\.onclick=\(\)=>nav\('#\/customer\/programmes'\)/);
  assert.doesNotMatch(shell,/history\.back/);
  assert.match(app,/function focusCustomerRoute\(\)\{[\s\S]*CUI\.focusRoute\(main,\{enhanceContent:true\}\)/);

  const context=section('async function loadCustomerSurfaceContext','async function renderCustomerProgrammes');
  assert.match(context,/customerSurfaceQualifies\(profile,customer\)/);
  assert.match(context,/renderNoCustomerDestination\(staff\)/);
  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  assert.match(wallet,/loadCustomerSurfaceContext\(isWalletCurrent\)/);
});

test('customer home and destinations reuse existing customer contracts with honest unavailable states',()=>{
  const surfaces=section('async function loadCustomerSurfaceContext','async function renderCustomerClaim');
  for(const rpc of [
    'get_my_personas',
    'customer_get_actionable_wallet',
    'customer_get_wallet',
    'customer_get_appointments_page',
    'customer_get_profile',
    'customer_update_profile'
  ])assert.match(surfaces,new RegExp(`sb\\.rpc\\('${rpc}'`));
  assert.match(surfaces,/p_cursor:\{limit:20\}/);
  assert.match(surfaces,/renderCustomerWalletRetry\('Your rewards are temporarily unavailable\.',null,\(\)=>renderCustomerProgrammes\(\)\)/);
  assert.match(surfaces,/Your booking requests and appointments are temporarily unavailable/);
  assert.match(surfaces,/Visit the business and scan its Peekaa QR/);
  assert.match(surfaces,/if\(!cards\.length\)\{renderCustomerFirstProgrammeQuest\(\);return\}/);
  assert.doesNotMatch(surfaces,/href="#\/claim"/);
  assert.match(surfaces,/Active requests, confirmed appointments, and recent request outcomes stay separate/);
  assert.match(surfaces,/if\(context\.features\.customer_in_app_inbox!==true\)\{[\s\S]*Messages are not available[\s\S]*This feature is not available for your account right now/,
    'a manually entered disabled Messages destination must remain visible with an honest unavailable state');
  assert.match(surfaces,/await renderCustomerInAppInbox\(null,isCurrent\)/,
    'an enabled Messages destination must render the existing customer inbox rather than placeholder copy');
  assert.match(surfaces,/Profile editing is not available/);
  assert.match(surfaces,/Date of birth/);
  assert.match(surfaces,/not editable here/);

  const home=section('function customerHomeNextActionMarkup','async function renderCustomerWallet');
  assert.match(home,/ct\('chooseProgramme'\)/);
  assert.match(home,/ct\('programmesIntro'\)/);
  assert.match(home,/id="customerHomeScan"/);
  assert.match(home,/ct\('addProgramme'\)/);
  assert.match(home,/if\(!cards\.length\)\{[\s\S]*customer-first-quest/,
    'an empty actionable wallet must retain the first-programme QR journey inline');
  assert.match(home,/customerHomeGuidanceV167\(\{pendingRedemption,actionableCards:cards,legacyCards,offers:offersState\.items\}\)/,
    'Home guidance must use the canonical V167 priority and fallback renderer');
  assert.match(home,/Next best action/);
  assert.match(home,/No urgent action is available right now/);
  assert.match(home,/href="#\/wallet\/\$\{slug\}"/);
  assert.doesNotMatch(home,/href="#\/claim"/);

  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  assert.match(wallet,/const context=await loadCustomerSurfaceContext\(isWalletCurrent\)/);
  const syncAt=wallet.indexOf("const syncRpc='customer_sync_in_app_inbox_global'");
  const countAt=wallet.indexOf("return sb.rpc('customer_get_in_app_inbox_global_count')");
  assert.ok(syncAt>=0&&countAt>syncAt,'home must sync the global inbox before claiming a current unread count');
  assert.match(wallet,/claimsAvailable:false/);
  assert.match(wallet,/customer_create_redemption_intent_v89/);
  assert.match(wallet,/intent\?\.status!=='pending'\|\|!intent\?\.qr_token/);
});
