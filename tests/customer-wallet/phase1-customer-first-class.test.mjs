import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../../',import.meta.url);
const app=await readFile(new URL('app/index.html',root),'utf8');
const brand=await readFile(new URL('app/brand-config.js',root),'utf8');

const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.notEqual(from,-1,`missing section ${start}`);
  assert.notEqual(to,-1,`missing section boundary ${end}`);
  return app.slice(from,to);
};

test('business and customer are equal first-class entry paths before authentication',()=>{
  assert.match(brand,/productName:\s*'Nestly'/);
  assert.match(brand,/customerLabel:\s*'My Nestly'/);
  const entry=section('function renderEntryChoice()','function renderPersonaChoice(personas)');
  assert.match(entry,/class="entry-choice-grid"/);
  assert.match(entry,/class="entry-choice" href="#\/business"/);
  assert.match(entry,/class="entry-choice" href="#\/customer"/);
  assert.match(entry,/<h2>Business<\/h2>/);
  assert.match(entry,/<h2>Customer<\/h2>/);
  assert.match(entry,/CUI\.icon\('branch'/);
  assert.match(entry,/CUI\.icon\('customers'/);
  assert.match(entry,/<main[^>]*id="main"[^>]*tabindex="-1"/);

  const auth=section("function renderAuth(mode='in')",'function validNewPassword');
  assert.match(auth,/class="entry-path-switch" aria-label="Account type"/);
  assert.match(auth,/href="#\/business" aria-current="page"/);
  assert.match(auth,/href="#\/customer" id="customerAuth"/);
});

test('dual-role root presents an explicit destination choice and direct deep links remain authoritative',()=>{
  const routing=section('async function route()','/* ---------- customer wallet ---------- */');
  assert.match(routing,/hasCustomerDestination&&staffPersonas\.length\)\{renderPersonaChoice\(\{\.\.\.rootPersonas/);
  assert.doesNotMatch(routing,/customerPersonas\.length&&staffPersonas\.length\)\{nav\(rootPersonas\.default_route/);

  const chooser=section('function renderPersonaChoice(personas)','function renderAuth');
  assert.match(chooser,/<h2 id="personaWorkspacesTitle">Business workspaces<\/h2>/);
  assert.match(chooser,/<h2>\$\{esc\(BRAND\.customerLabel\)\}<\/h2>/);
  assert.match(chooser,/staff\.map\(workspace=>`<a class="btn ghost sm" href="#\/workspace\/\$\{encodeURIComponent\(workspace\.business_slug\)\}\/dashboard"/);
  assert.match(chooser,/href="#\/wallet"/);
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

test('persistent customer navigation has exactly five labelled icon-and-text destinations',()=>{
  const nav=section('const CUSTOMER_PRIMARY_NAV=Object.freeze([',']);\nfunction customerPrimaryNavigation');
  assert.equal((nav.match(/\{key:/g)||[]).length,5);
  for(const [key,href,label] of [
    ['home','#/wallet','Home'],
    ['programmes','#/customer/programmes','Programmes'],
    ['bookings','#/customer/bookings','Bookings'],
    ['messages','#/customer/messages','Messages'],
    ['profile','#/customer/profile','Profile']
  ]){
    assert.match(nav,new RegExp(`key:'${key}',href:'${href.replaceAll('/','\\/')}'[^\\n]*label:'${label}'`));
  }
  const navMarkup=section('function customerPrimaryNavigation(active)','function renderCustomerShell');
  assert.match(navMarkup,/<nav class="customer-primary-nav" aria-label="\$\{esc\(BRAND\.customerLabel\)\}">/);
  assert.match(navMarkup,/aria-current="page"/);
  assert.match(navMarkup,/CUI\.icon\(item\.icon/);
  assert.match(navMarkup,/<span>\$\{item\.label\}<\/span>/);

  assert.match(app,/\.customer-primary-nav\{[^}]*grid-template-columns:repeat\(5,minmax\(0,1fr\)\)/s);
  assert.match(app,/\.customer-primary-nav a\{[^}]*min-height:48px/s);
  assert.match(app,/@media\(max-width:720px\)\{[\s\S]*\.customer-primary-nav\{position:fixed[^}]*bottom:/);
});

test('customer shell, deep links, and profile transitions are predictable and accessible',()=>{
  const shell=section('function renderCustomerShell','function focusCustomerRoute');
  assert.match(shell,/<a class="logo" href="#\/wallet" aria-label="\$\{esc\(BRAND\.customerLabel\)\} home"/);
  assert.match(shell,/<main id="main" tabindex="-1">/);
  assert.match(shell,/customerWorkspaceSwitchHtml\(staffWorkspaces\)/);
  assert.match(shell,/id="walletSignOut"[^>]*aria-label="Sign out of \$\{esc\(BRAND\.customerLabel\)\}"/);
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
  assert.match(surfaces,/renderCustomerWalletRetry\('Your programmes are temporarily unavailable\.',null,\(\)=>renderCustomerProgrammes\(\)\)/);
  assert.match(surfaces,/Your booking requests and appointments are temporarily unavailable/);
  assert.match(surfaces,/Add programme/);
  assert.match(surfaces,/href="#\/claim"/);
  assert.match(surfaces,/Active requests, confirmed appointments, and recent request outcomes stay separate/);
  assert.match(surfaces,/Messages are not available yet/);
  assert.match(surfaces,/Profile editing is not available/);
  assert.match(surfaces,/Date of birth/);
  assert.match(surfaces,/not editable here/);

  const home=section('function renderActionableWalletHome','async function renderCustomerWallet');
  assert.match(home,/Next best action/);
  assert.match(home,/Rewards, value &amp; visits/);
  assert.match(home,/Balances are never combined across businesses/);
  assert.match(home,/>Visits</);
  assert.match(home,/Booking summary is temporarily unavailable/);
  assert.match(home,/Message count is temporarily unavailable/);
  assert.match(home,/customerHomeOverview\.claimsAvailable\?[\s\S]*href="#\/claim"/);
  assert.match(home,/Programme linking is not available right now/);

  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  assert.match(wallet,/const context=await loadCustomerSurfaceContext\(isWalletCurrent\)/);
  const syncAt=wallet.indexOf("const syncRpc='customer_sync_in_app_inbox_global'");
  const countAt=wallet.indexOf("return sb.rpc('customer_get_in_app_inbox_global_count')");
  assert.ok(syncAt>=0&&countAt>syncAt,'home must sync the global inbox before claiming a current unread count');
  assert.match(wallet,/claimsAvailable:customerFeatures\.customer_claims===true/);
});
