import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const root=new URL('../../',import.meta.url);
const [app,ui]=await Promise.all([
  Promise.all([readFile(new URL('app/index.html',root),'utf8'),readFile(new URL('app/app.js',root),'utf8')]).then(f=>f.join('\n')),
  readFile(new URL('app/customer-ui.js',root),'utf8')
]);

const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.notEqual(from,-1,`missing section ${start}`);
  assert.notEqual(to,-1,`missing section boundary ${end}`);
  return app.slice(from,to);
};
const clients=section('async function clientsPage()','async function clientDetail(');
const detail=section('async function clientDetail(','async function tillPage()');
const till=section('async function tillPage()','async function salesPage()');
const loyalty=section('async function loyaltyPage(','async function retentionPage(');
const retention=section('async function retentionPage(','async function referralsPage()');
const referrals=section('async function referralsPage()','async function membershipsPage()');
const memberships=section('async function membershipsPage()','async function giftcardsPage()');
const giftcards=section('async function giftcardsPage()','async function appointmentsPage()');

function rgb(hex){
  const value=Number.parseInt(hex.slice(1),16);
  return [(value>>16)&255,(value>>8)&255,value&255];
}
function luminance(hex){
  return rgb(hex).map(v=>v/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4)
    .reduce((sum,v,index)=>sum+v*[.2126,.7152,.0722][index],0);
}
function contrast(a,b){
  const [light,dark]=[luminance(a),luminance(b)].sort((x,y)=>y-x);
  return (light+.05)/(dark+.05);
}
/* Tokens may now be declared as an alias of another token (--coral:var(--brand-red)) since the
   brand red was consolidated to one source. Resolve one chain of aliases so every contrast gate
   below keeps measuring the colour that actually renders. */
function token(name,depth=0){
  const raw=app.match(new RegExp(`--${name}:\\s*(#[0-9A-Fa-f]{6}|var\\(--[A-Za-z0-9-]+\\))`))?.[1];
  if(!raw)return undefined;
  const alias=raw.match(/^var\(--([A-Za-z0-9-]+)\)$/);
  if(alias)return depth<4?token(alias[1],depth+1):undefined;
  return raw;
}

test('warm-coral text and component boundary tokens meet WCAG contrast targets',()=>{
  for(const name of ['coral','muted','green','red']){
    assert.ok(contrast(token(name),'#FFFFFF')>=4.5,`${name} must be readable on white`);
  }
  assert.ok(contrast(token('coral'),token('bg'))>=4.5,'primary coral must be readable on the app background');
  assert.ok(contrast(token('muted'),token('bg'))>=4.5,'muted text must be readable on the app background');
  assert.ok(contrast(token('control-border'),'#FFFFFF')>=3,'control boundary must reach non-text 3:1 contrast');
  assert.match(app,/input:not\(\[type=\"checkbox\"\]\):not\(\[type=\"radio\"\]\),select,textarea\{[^}]*border:1px solid var\(--control-border\)/s);
  assert.match(app,/\.btn\.ghost\{[^}]*border:1px solid var\(--control-border\)/s);
  assert.match(app,/\.qbtn\{[^}]*border:1px solid var\(--control-border\)/s);
});

test('local dependency-free UI primitives and inline SVG icons are build-safe',()=>{
  assert.match(app,/<script src="\/customer-ui\.js\?v=[a-z0-9-]+"><\/script>/);
  assert.ok(app.indexOf('/customer-ui.js')<app.indexOf('const CUI=window.FrenlyCustomerUI'));
  for(const primitive of ['icon','action','status','permissionBanner','pageHeader','card','field','emptyState','loadingState','errorState','table']){
    assert.match(ui,new RegExp(`function ${primitive}\\(`));
  }
  assert.match(ui,/<svg class="cui-icon/);
  assert.doesNotMatch(ui,/https?:\/\//);
  assert.match(app,/CUI\.icon\(MODULES\[m\]\[0\]/,'all non-nav module icon consumers must render the icon key');
});

test('auth fields are explicitly labelled and normal login avoids a denied Platform probe',()=>{
  const auth=section('function renderAuth(','function validNewPassword(');
  const passwordUpdate=section('function renderPasswordUpdate()','function renderRecoveryInvalid()');
  const bootstrap=section('async function route()','/* ---------- auth ---------- */');
  const resolver=section("const {data:mm,error:mmErr}=await sb.rpc('get_my_modules'",'if(S.hasCustomerPersona===null)');

  assert.ok(
    (auth.match(/<label for="em">Email<\/label><input id="em"/g)||[]).length>=2,
    'sign-in and reset-request email fields should have explicit associations',
  );
  assert.match(auth,/<label for="pw">Password<\/label>\$\{passwordControlHtml\('pw'/);
  assert.match(passwordUpdate,/<label for="newPw">New password<\/label>\$\{passwordControlHtml\('newPw'/);
  assert.match(passwordUpdate,/<label for="confirmPw">Confirm new password<\/label>\$\{passwordControlHtml\('confirmPw'/);
  assert.match(app,/function passwordControlHtml\(id,/);
  assert.match(app,/data-password-toggle=/);
  assert.match(app,/function bindPasswordVisibility\(container=document\)/);
  assert.match(resolver,/if\(mmErr\|\|!mm\)[\s\S]*S\.isSA=false/);
  assert.match(resolver,/S\.isSA=mm\.is_super_admin===true/);
  assert.match(bootstrap,/S\.saChecked=true/);
  assert.doesNotMatch(bootstrap,/super_admin_list_businesses/);
  assert.equal(
    (app.match(/sb\.rpc\('super_admin_list_businesses'\)/g)||[]).length,
    1,
    'the gated business-list RPC should run only on the Platform page',
  );
});

test('inactive staff stop before page data calls with a reactivation and sign-out state',()=>{
  const bootstrap=section('async function route()','/* ---------- auth ---------- */');
  const guardStart=bootstrap.indexOf("const hasResolvedStaffRole=typeof S.myRole==='string'");
  const personaLoad=bootstrap.indexOf('if(S.hasCustomerPersona===null)');
  const pageDispatch=bootstrap.indexOf("const page=workspacePage?");

  assert.notEqual(guardStart,-1,'inactive staff guard must follow server module resolution');
  assert.ok(guardStart<personaLoad&&personaLoad<pageDispatch,'inactive staff must return before persona and page loaders');
  assert.match(bootstrap,/const hasResolvedStaffModules=Array\.isArray\(S\.myModules\)&&S\.myModules\.length>0/);
  assert.match(bootstrap,/if\(!S\.isSA&&!hasResolvedStaffRole&&!hasResolvedStaffModules\)\{[\s\S]*return renderWorkspaceAccessUnavailable\(\)/);
  assert.match(bootstrap,/function renderWorkspaceAccessUnavailable\(\)[\s\S]*Workspace access unavailable/);
  assert.match(bootstrap,/id="workspaceAccessSignOut"[\s\S]*sb\.auth\.signOut\(\)[\s\S]*resetClientSessionState\(\)/);
});

test('inactive-access legal links are semantic WCAG targets on desktop and 390px',()=>{
  const mobile=section('/* === COMPACT LAYOUT SHELL (<=768px)','@media(max-width:375px){');

  assert.match(app,/const legalLinks=\(locale='en'\)=>\{/);
  assert.match(app,/return `<nav class="legal-links" aria-label="\$\{esc\(copy\.label\)\}">/);
  for(const [href,label,key] of [
    ['/privacy.html','Privacy','privacy'],['/terms.html','Terms','terms'],['/data-request.html','Data request','data'],
  ]){
    assert.match(app,new RegExp(`${key}:['"]${label.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}['"]`));
    assert.match(app,new RegExp(`<a href="${href.replace(/[/.]/g,'\\$&')}">\\$\\{esc\\(copy\\.${key}\\)\\}<\\/a>`));
  }
  assert.match(app,/\.legal-links a\{[^}]*display:inline-flex[^}]*min-height:44px[^}]*padding:8px[^}]*color:var\(--muted\)/s);
  assert.match(mobile,/\.legal-links\{[^}]*width:100%[^}]*max-width:100%[^}]*\}[\s\S]*\.legal-links a\{[^}]*min-height:44px/s);
});

test('target customer routes use SVG icons instead of raw structural glyphs',()=>{
  for(const source of [detail,till,loyalty])assert.doesNotMatch(source,/[⏳🏆🎁⏸←]/u);
  assert.match(detail,/CUI\.icon\('waitlist',\{size:15\}\)/);
  assert.match(detail,/CUI\.icon\('loyalty',\{size:17\}\)/);
  assert.match(till,/CUI\.icon\('back',\{size:17\}\)/);
  assert.match(till,/CUI\.icon\('forward',\{size:18\}\)/);
  assert.match(loyalty,/CUI\.icon\('retention',\{size:15\}\)/);
});

test('shell and route accessibility provide skip, focus, landmarks, and one announcement per event',()=>{
  assert.match(app,/<a class="skip-link" href="#main">Skip to main content<\/a>/);
  assert.match(app,/<main class="main" id="main" tabindex="-1">/);
  assert.match(app,/:where\(a,button,input,select,textarea,\[tabindex\]:not\(\[tabindex="-1"\]\)\):focus-visible/);
  assert.match(app,/CUI\.focusRoute\(main,\{enhanceContent:enhanceCustomerUi\}\)/);
  assert.match(app,/id="appStatus"[^>]*aria-live="polite"/);
  assert.match(app,/id="appAlert"[^>]*aria-live="assertive"/);
  assert.match(app,/id="toast" class="toast" aria-hidden="true"/);
  assert.match(app,/const toast=m=>\{[^}]*CUI\.announce\(message\)/s);
  assert.match(app,/const fail=e=>\{[^}]*CUI\.announce\(message,\{assertive:true\}\)/s);
});

test('targets, mobile layouts, reflowing tables, and reduced motion are explicit',()=>{
  assert.match(app,/\.btn\{[^}]*min-height:44px/s);
  assert.match(app,/\.btn\.sm\{[^}]*min-height:44px/s);
  assert.match(app,/\.qbtn\{[^}]*min-height:44px/s);
  assert.match(app,/\.wallet-head>a\.logo\{[^}]*display:inline-flex[^}]*align-items:center[^}]*min-height:44px/s);
  assert.match(app,/\.challenge-retry\{[^}]*display:inline-flex[^}]*align-items:center[^}]*min-height:44px/s);
  assert.match(app,/\.skip-link\{[^}]*min-height:44px/s);
  /* The 44px minimum touch target on form controls is intact but tokenised: the rule now says
     min-height:var(--control-h) and --control-h is 44px. Assert both halves rather than the old
     literal, so a real shrink still fails but a token refactor does not. */
  assert.match(app,/input:not\(\[type=\"checkbox\"\]\):not\(\[type=\"radio\"\]\),select,textarea\{[^}]*min-height:var\(--control-h\)/s);
  assert.match(app,/--control-h:\s*44px/);
  assert.match(app,/@media\(max-width:375px\)/);
  assert.match(app,/@media\(min-width:376px\) and \(max-width:768px\)/);
  assert.match(app,/@media\(max-width:768px\)[\s\S]*content:attr\(data-label\)/);
  assert.match(app,/@media\(prefers-reduced-motion:reduce\)/);
  assert.match(ui,/const isComplex=!!table\.querySelector\('\[colspan\],\[rowspan\]'\)/);
  assert.match(ui,/looseRows\.forEach\(row=>body\.append\(row\)\)/);
  assert.match(ui,/cell\.dataset\.label=headers\[index\]/);
});

test('dashboard and customer loyalty detail preserve accessible names and one page heading',()=>{
  const dashboard=section('async function dashboard(){','/* ---------- customers ---------- */');
  const walletCard=section('function actionableWalletCardMarkup(','function renderActionableWalletHome(');

  assert.match(dashboard,/<label class="sr-only" for="df">Dashboard start date<\/label>/);
  assert.match(dashboard,/<label class="sr-only" for="dt">Dashboard end date<\/label>/);
  /* The branch selector is now rendered into a wrapper, so the id no longer sits on the
     <select> itself. What must not regress is its accessible name, so pin that. */
  assert.match(app,/<select class="qbtn" aria-label="Business branch"/);
  /* Every tier control still needs a programmatic label; V182 promoted three of them from
     sr-only to VISIBLE labels, because an unlabelled "1.25" box was unreadable to sighted
     owners too. The invariant is "has a <label for=>", not "has a hidden one". trPerk stays
     sr-only: it sits inside a titled <details>, so a second visible label would be noise. */
  for(const id of ['trName','trTh','trMul','trPerk']){
    assert.match(loyalty,new RegExp(`<label(?: class="sr-only")? for="${id}">`),
      `${id} must have a programmatic label`);
  }
  for(const id of ['trName','trTh','trMul']){
    assert.doesNotMatch(loyalty,new RegExp(`<label class="sr-only" for="${id}">`),
      `${id} is a primary tier field and must be visibly labelled`);
  }
  assert.doesNotMatch(walletCard,/h\$\{detail\?'1':'2'\}/);
  assert.match(walletCard,/<h2>\$\{esc\(business\.name\|\|'Business'\)\} rewards<\/h2>/);
  /* v178 made the label conditional: business pages keep the translated backProgrammes,
     the My Rewards tab (owner-requested back button) reads 'Back to home'. */
  assert.match(app,/id="walletBack" aria-label="\$\{esc\(backLabel\)\}"[^>]*min-width:44px/);
  assert.match(app,/backLabel=businessSlug\?ct\('backProgrammes'\):'Back to home'/);
  assert.match(loyalty,/if\(canManageLoyalty\)\{[\s\S]{0,300}?get_active_birthday_program/,
    'read-only staff must not call the owner-only birthday programme RPC');
});

test('mobile Retention actions wrap and role-aware workspace navigation stays thumb-reachable',()=>{
  assert.match(retention,/class="retention-taxonomy-row"/);
  assert.match(retention,/class="retention-taxonomy-actions"/);
  assert.match(app,/\.retention-taxonomy-row\{[^}]*flex-wrap:wrap[^}]*min-width:0/s);
  assert.match(app,/\.retention-taxonomy-copy\{[^}]*flex-wrap:wrap[^}]*min-width:0/s);
  assert.match(app,/\.retention-taxonomy-actions\{[^}]*flex-wrap:wrap[^}]*min-width:0/s);
  const mobileShell=section('@media(max-width:960px){','/* === COMPACT LAYOUT SHELL (<=768px)');
  assert.match(mobileShell,/\.shell\{[^}]*grid-template-columns:minmax\(0,1fr\)[^}]*max-width:100vw[^}]*min-width:0/s);
  assert.match(mobileShell,/\.side\{display:none\}/);
  assert.match(mobileShell,/\.staff-mobile-dock\{[^}]*position:fixed[^}]*bottom:0[^}]*display:grid/s);
  assert.match(app,/function staffMobileActionsHtml\(page\)[\s\S]*canScanCustomerRedemption\(\{[\s\S]*loyaltyWritable:canWriteModule\('loyalty'\)[\s\S]*id="staffMobileScan"/);
  assert.match(app,/staff-mobile-drawer[\s\S]*navHtml\(page,'mobile-nav'\)/);
  assert.doesNotMatch(mobileShell,/overflow-x:auto|flex:0 0 max-content/);
});

test('Settings forms are explicitly labelled and reflow without 390px page overflow',()=>{
  const settings=section('async function settingsPage()','/* ---------- billing (read-only) ---------- */');
  /* V243: the customer-facing half of Settings became its own top-level module. The forms are the
     SAME markup, lifted whole rather than copied, so the labelling contract is asserted where the
     markup now lives instead of being dropped. */
  const customerInterface=section('function customerInterfaceSectionsHtmlV243(','function wireCustomerInterfaceV243(');
  /* V259: the owner drew arrows from Workspace & brand onto the same Customer Interface module,
     so that form followed the other two. It is still ONE definition behind ONE #bsave save — the
     labelling contract simply moved with it. */
  const brand=section('function workspaceBrandPanelHtmlV259(){','function wireWorkspaceBrandV259(){');
  const bookingRules=section('function bookingRulesCardHtmlV325(){','function wireBookingRulesV325(');
  const mobile=section('/* === COMPACT LAYOUT SHELL (<=768px)','@media(max-width:375px){');

  assert.match(settings,/<div class="settings-page">/);
  assert.match(customerInterface,/<div class="customer-interface-sections-v243">/);
  for(const [source,id,label] of [
    /* V375 (owner, photo 17: "remove") — the brand colour picker is gone from the form. */
    [brand,'bn','Name'],[brand,'bi','Industry'],
    /* V385 (owner, photo 12): the booking policy moved to Appointment Setting, and is labelled
       there. The customer-facing industry wording (photo 11) joined this form and is labelled here. */
    [bookingRules,'bp','Booking policy (shown to customers when they book)'],
    [brand,'bilabel','What customers see under your name'],[settings,'ir','Invite role'],
    [settings,'ie','Invite email (optional)'],[customerInterface,'csvf','Customer CSV file'],
    /* V375 (owner, photo 16): the custom customer-field editor and its four labelled inputs
       were deleted with the card that held them. */
  ])assert.match(source,new RegExp(`<label[^>]*for="${id}"[^>]*>${label.replace(/[()]/g,'\\$&')}<\\/label>`));
  assert.match(customerInterface,/id="csvf"[^>]*aria-describedby="csvHelp"/);
  assert.match(app,/\.settings-page,\.settings-page \.split,\.settings-page \.card\{[^}]*min-width:0[^}]*max-width:100%/s);
  assert.match(mobile,/\.settings-page \.row\{[^}]*flex-wrap:wrap[^}]*width:100%/s);
  assert.match(mobile,/\.settings-page \.row>input,\.settings-page \.row>select\{[^}]*width:100%[^}]*max-width:100%!important/s);
  assert.match(app,/\.settings-choice\{[^}]*min-height:44px/s);
  /* V385 (owner, photo 8: the portal link struck through with "delete"). It left the Business
     Profile form, where it sat between the last field and Save. The link itself is not gone from
     the product — Appointments prints it at the top of its own page, which is where an owner is
     when they want to share it, and it is still the same wrapping-safe markup. */
  assert.doesNotMatch(brand,/portal-link-row/,'the portal link is not part of this form any more');
  assert.match(app,/<p class="small portal-link-row"><a class="portal-link" href="\$\{appointmentsPortalLinkV375\}" target="_blank" rel="noopener noreferrer">/);
  assert.match(app,/\.portal-link\{[^}]*display:flex[^}]*width:100%[^}]*max-width:100%[^}]*min-height:44px[^}]*overflow-wrap:anywhere[^}]*word-break:break-word/s);
  assert.match(mobile,/\.portal-link-row,\.portal-link\{[^}]*width:100%[^}]*max-width:100%[^}]*min-width:0/s);
  assert.ok(contrast('#A64020','#FFFFFF')>=4.5,'portal URL text must meet WCAG AA on white');
});

test('customer sign-up join URL is a safe 44px target without 390px overflow',()=>{
  /* V368: the QR card renders into a host it is handed (the profile menu's dialog) rather than a
     fixed page card, so the function takes one argument now. Same body, same RPCs. */
  const signup=section('async function loadSignupConfig(host)','async function loadCommissionConfig()');
  const mobile=section('/* === COMPACT LAYOUT SHELL (<=768px)','@media(max-width:375px){');

  assert.match(signup,/<p class="small portal-link-row" id="joinQrLink"[^>]*><\/p>/);
  assert.match(signup,/\$\('joinQrLink'\)\.innerHTML=`<a class="portal-link" target="_blank" rel="noopener noreferrer" href="\$\{esc\(url\)\}">\$\{esc\(url\)\}<\/a>`/);
  assert.match(signup,/business_rotate_customer_join_qr_v90/);
  assert.match(signup,/business_revoke_customer_join_qrs_v90/);
  assert.match(signup,/business_get_customer_join_qr_status_v91/);
  assert.match(signup,/business_ensure_customer_join_qr_v91/);
  /* V209 (owner, twice: "make it static ... only have 1 - not multiple different variations").
     The panel used to draw the QR ONLY when created === true, so an owner who already had one
     could never see it again — the only route back to their own code was to destroy it and print
     a new one. The token is an HMAC of business:version, so the server recomputes the SAME code
     forever; the panel now draws whenever a token comes back, created or not. */
  assert.match(signup,/else if\(statusResult\.data\?\.join_token\)\{[\s\S]*showJoinQr\(statusResult\.data\)/);
  assert.match(signup,/This is your permanent sign-up code/);
  assert.match(signup,/publicAppUrl\(`join\?token=\$\{encodeURIComponent\(data\.join_token\)\}`\)/);
  assert.match(app,/\.portal-link\{[^}]*display:flex[^}]*width:100%[^}]*max-width:100%[^}]*min-height:44px[^}]*overflow-wrap:anywhere[^}]*word-break:break-word/s);
  assert.match(mobile,/\.portal-link-row,\.portal-link\{[^}]*width:100%[^}]*max-width:100%[^}]*min-width:0/s);
});

test('foreign workspace denials expose a focused main landmark and page heading',()=>{
  const routing=section('async function route()','/* ---------- customer wallet ---------- */');
  assert.equal((routing.match(/<h1 id="workspaceUnavailableTitle"/g)||[]).length,2);
  assert.equal((routing.match(/<main class="center-wrap" id="main" tabindex="-1">/g)||[]).length,2);
  assert.equal((routing.match(/\$\('main'\)\.focus\(\)/g)||[]).length,2);
});

test('progressive enhancement covers every workspace route',()=>{
  /* V287 grew a per-route allowlist one mobile-table bug at a time; v294 ends it. enhanceTables
     is idempotent and adds markup only where absent, so mounting everywhere removes the failure
     mode instead of curating it. */
  assert.doesNotMatch(app,/customerUiRoutes/);
  assert.match(app,/customerUiObserver=CUI\.mountMain\(main\)/);
  assert.match(app,/if\(customerUiObserver\)customerUiObserver\.disconnect\(\)/);
});

test('customer list has search, keyboard links, pagination, export/import, and latest-response safety',()=>{
  assert.match(clients,/id="clientSearch" type="search"/);
  assert.match(clients,/Search customers by name or phone/);
  /* The customer directory must read through a tenant-scoped, versioned RPC rather than a raw
     table query. The VERSION deliberately is not pinned: this reader has moved v129 -> v154 ->
     v155 and each bump broke this assertion without anything actually regressing. What matters
     is the shape, so that is what is asserted. */
  assert.match(clients,/sb\.rpc\('staff_list_customers_v\d+'/);
  assert.match(clients,/const customerRpcSearch=normalizeCustomerSearchPhoneDigits\(clientSearch\)\|\|clientSearch/);
  assert.match(clients,/const customerDirectoryPage=[\s\S]{0,400}sb\.rpc\('staff_list_customers_v\d+',[\s\S]{0,120}p_search:search\|\|null/);
  /* The inactivity filter must cover the WHOLE directory, not just the page on screen. It used
     to be a server-side p_inactive_days argument; it is now a full paged fetch plus a
     client-side bucket filter. Either is correct; filtering one page is not. */
  assert.match(clients,/if\(clientInactiveBucket\)\{[\s\S]{0,200}await allCustomerDirectoryRows\(\)/);
  assert.match(clients,/while\(total===null\|\|offset<total\)/);
  const normalizerLine = app.split('\n')
    .find((line) => line.startsWith('const normalizeCustomerSearchPhoneDigits='));
  assert.ok(normalizerLine, 'customer phone-search normalizer must be defined');
  const normalizeCustomerSearchPhoneDigits = Function(
    `return (${normalizerLine.slice(normalizerLine.indexOf('=') + 1, -1)})`,
  )();
  assert.equal(normalizeCustomerSearchPhoneDigits('+65 8123 4567'), '81234567');
  assert.equal(normalizeCustomerSearchPhoneDigits('8123'), '8123');
  assert.match(clients,/CUI\.action\(\{id:'exp',label:'Export CSV'/);
  assert.match(clients,/importBtn\('customers'\)/);
  assert.match(clients,/CUI\.action\(\{id:'add',label:'Add customer'/);
  assert.match(clients,/createLatestRequestGate\(isCustomersCurrent\)/);
  assert.match(clients,/const isCurrent=customerLoadGate\.begin\(\)/);
  assert.ok((clients.match(/if\(!isCurrent\(\)\)return/g)||[]).length>=1);
  assert.match(clients,/<a class="customer-link" href="#\/client\/\$\{c\.id\}"/);
  assert.doesNotMatch(clients,/<tr class="click" onclick=/);
  assert.match(clients,/id="clPrev"/);assert.match(clients,/id="clNext"/);
});

test('read-only referral, membership, and gift-card views omit editable transaction forms',()=>{
  assert.match(referrals,/const referralSettings=canWrite\?`<label for="fe"/);
  assert.match(referrals,/:`<dl class="cui-readonly-list" aria-label="Referral program settings"/);
  assert.match(memberships,/const planEditor=canWrite\?`<label for="mn"/);
  assert.match(memberships,/const enrollmentEditor=canEnroll\?`<label for="ec"/);
  assert.match(memberships,/if\(canEnroll&&\$\('ego'\)\)/);
  assert.match(giftcards,/const issueWorkspace=canIssue\?`/);
  assert.match(giftcards,/const redeemWorkspace=canRedeem\?`/);
  assert.match(giftcards,/if\(canIssue&&\$\('gsell'\)\)/);
  assert.match(giftcards,/if\(canRedeem&&\$\('gredeem'\)\)/);
});

test('financial UI actions require module rights plus server-mirrored create-sales capability',()=>{
  assert.match(app,/owner:new Set\(\['create_sales','view_finance'\]\),manager:new Set\(\['create_sales','view_finance'\]\),staff:new Set\(\['create_sales'\]\)/);
  assert.match(app,/frontdesk:new Set\(\['create_sales'\]\),bookkeeper:new Set\(\['view_finance'\]\)/);
  assert.match(detail,/const canWriteLoyaltyConfigured=canWriteModule\('loyalty'\)&&hasRoleCapability\('create_sales'\)/);
  assert.match(detail,/const canWriteLoyalty=canWriteLoyaltyConfigured&&loyaltyFactsAvailable/);
  assert.match(memberships,/const canEnroll=canWrite&&hasRoleCapability\('create_sales'\)/);
  assert.match(giftcards,/const abilities=giftCardAbilitiesV102\(\{[\s\S]*createSales:hasRoleCapability\('create_sales'\),[\s\S]*giftcardsReadable:branchCanRead\(giftBranchId,'giftcards'\),[\s\S]*giftcardsWritable:branchCanWrite\(giftBranchId,'giftcards'\),[\s\S]*businessEnabled:giftCardsEnabled/);
  assert.match(giftcards,/const canIssue=abilities\.canIssue/);
  assert.match(giftcards,/const canRedeem=hasRoleCapability\('create_sales'\)[\s\S]*branchCanWrite\(giftBranchId,'till'\)[\s\S]*branchCanRead\(giftBranchId,'clients'\)/);
  assert.match(till,/const canRecordSalesAtWorkspace=hasRoleCapability\('create_sales'\)&&canReadModule\('clients'\)/);
  assert.match(till,/if\(!canRecordSalesAtWorkspace\)[\s\S]*Additional access required/);
  assert.match(till,/const accessibleTillBranches=assignedTillBranches\.filter\(branch=>\s*branchCanWrite\(branch\.id,'till'\)&&branchCanRead\(branch\.id,'clients'\)\s*\)/);
  assert.match(till,/const canRecordSales=hasRoleCapability\('create_sales'\)&&Boolean\(tillBranchId\)/);
  assert.match(till,/if\(!tillStaffId\|\|!tillBranchId\)[\s\S]*Record sale is not available/);
  assert.match(detail,/confirmCompleteFacet\('loyalty'\)/);
});

test('customer route async renders cannot overwrite a newer route',()=>{
  assert.match(detail,/const isClientDetailCurrent=.*M\(\)===routeMain/);
  assert.ok((detail.match(/if\(!isClientDetailCurrent\(\)\)return/g)||[]).length>=2);
  assert.match(loyalty,/const isLoyaltyCurrent=.*M\(\)===routeMain/);
  assert.ok((loyalty.match(/if\(!isLoyaltyCurrent\(\)\)return/g)||[]).length>=4);
  assert.match(retention,/const isRetentionCurrent=.*M\(\)===routeMain/);
  assert.ok((retention.match(/if\(!isRetentionCurrent\(\)\)return/g)||[]).length>=3);
  for(const source of [referrals,memberships,giftcards])assert.match(source,/const is(?:Referrals|Memberships|GiftCards)Current=.*M\(\)===routeMain/);
});

test('customer routes paint loading, expose retryable failures, and ignore late mutation completions',()=>{
  for(const source of [detail,till,loyalty,retention,referrals,memberships,giftcards]){
    assert.match(source,/routeMain\.innerHTML=CUI\.loadingState\(/);
  }
  assert.match(app,/Promise\.resolve\(pageResult\)\.catch\(error=>/);
  assert.match(app,/main\.innerHTML=CUI\.errorState\(/);
  assert.match(app,/retry\.onclick=\(\)=>renderShell\(page\)/);
  /* A late response must not clobber a newer one, and a failed save must re-enable the button.
     The re-enable moved from a raw saveButton.disabled=false to the shared CUI.setButtonBusy
     helper; the ordering guarantee is what matters. */
  assert.match(clients,/if\(!isCustomersCurrent\(\)\)return;[\s\S]{0,120}if\(error\)\{CUI\.setButtonBusy\(saveButton,\{busy:false\}\)/);
  assert.ok((detail.match(/if\(!isClientDetailCurrent\(\)\)return/g)||[]).length>=5);
  assert.ok((till.match(/if\(!isTillCurrent\(\)\)return/g)||[]).length>=5);
  assert.ok((loyalty.match(/if\(!isLoyaltyCurrent\(\)\)return/g)||[]).length>=10);
  assert.ok((retention.match(/if\(!isRetentionCurrent\(\)\)return/g)||[]).length>=10);
  /* V322 (OWNER RULING R1/R4): the referral payout became POINTS, so the writer moved from
     save_referral_program (money) to save_referral_program_v322 (points). The claim this line
     protects is unchanged and is about ORDERING, not about the amount: the page checks it is still
     the current route before touching the DOM after the write. */
  assert.match(referrals,/await sb\.rpc\('save_referral_program_v322'[\s\S]{0,400}if\(!isReferralsCurrent\(\)\)return/);
  assert.match(memberships,/await sb\.rpc\('enroll_membership_v41'[\s\S]{0,250}if\(!isMembershipsCurrent\(\)\)return/);
  assert.match(giftcards,/await sb\.rpc\('issue_gift_card_at_branch_v117'[\s\S]{0,450}if\(!isGiftCardsCurrent\(\)\)return/);
});

test('customer dialogs and shell disclosures are keyboard complete and semantically reachable',()=>{
  assert.match(app,/id='impModal'|wrap\.id='impModal'/);
  assert.match(app,/setAttribute\('role','dialog'\)/);
  assert.match(app,/setAttribute\('aria-modal','true'\)/);
  assert.match(app,/id="reversalModal" role="dialog" aria-modal="true" aria-labelledby="revTitle"/);
  assert.match(ui,/event\.key==='Escape'/);
  assert.match(ui,/event\.key!=='Tab'/);
  assert.match(ui,/returnFocus\?\.isConnected/);
  assert.match(app,/<button type="button" class="navhead/);
  assert.match(app,/<button type="button" class="notif-item/);
  assert.match(app,/<button type="button" class="tglsw/);
  assert.doesNotMatch(app,/role="menuitem"/);
});
