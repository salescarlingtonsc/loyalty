import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const root=new URL('../../',import.meta.url);
const [app,ui]=await Promise.all([
  readFile(new URL('app/index.html',root),'utf8'),
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
function token(name){
  return app.match(new RegExp(`--${name}:(#[0-9A-Fa-f]{6})`))?.[1];
}

test('warm-coral text and component boundary tokens meet WCAG contrast targets',()=>{
  for(const name of ['coral','muted','green','red']){
    assert.ok(contrast(token(name),'#FFFFFF')>=4.5,`${name} must be readable on white`);
  }
  assert.ok(contrast(token('coral'),token('bg'))>=4.5,'primary coral must be readable on the app background');
  assert.ok(contrast(token('muted'),token('bg'))>=4.5,'muted text must be readable on the app background');
  assert.ok(contrast(token('control-border'),'#FFFFFF')>=3,'control boundary must reach non-text 3:1 contrast');
  assert.match(app,/input,select,textarea\{[^}]*border:1px solid var\(--control-border\)/s);
  assert.match(app,/\.btn\.ghost\{[^}]*border:1px solid var\(--control-border\)/s);
  assert.match(app,/\.qbtn\{[^}]*border:1px solid var\(--control-border\)/s);
});

test('local dependency-free UI primitives and inline SVG icons are build-safe',()=>{
  assert.match(app,/<script src="\/customer-ui\.js"><\/script>/);
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
  assert.match(auth,/<label for="pw">Password<\/label><input id="pw"/);
  assert.match(passwordUpdate,/<label for="newPw">New password<\/label><input id="newPw"/);
  assert.match(passwordUpdate,/<label for="confirmPw">Confirm new password<\/label><input id="confirmPw"/);
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
  assert.match(app,/:where\(a,button,input,select,textarea,\[tabindex\]\):focus-visible/);
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
  assert.match(app,/\.skip-link\{[^}]*min-height:44px/s);
  assert.match(app,/input,select,textarea\{[^}]*min-height:44px/s);
  assert.match(app,/@media\(max-width:375px\)/);
  assert.match(app,/@media\(min-width:376px\) and \(max-width:768px\)/);
  assert.match(app,/@media\(max-width:767px\)[\s\S]*content:attr\(data-label\)/);
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
  assert.match(app,/id="branchSel"[^>]*aria-label="Business branch"/);
  for(const [id,label] of [['trName','Tier name'],['trTh','Tier threshold'],['trMul','Points earning multiplier'],['trPerk','Tier perk note']]){
    assert.match(loyalty,new RegExp(`<label class="sr-only" for="${id}">${label}<\\/label>`));
  }
  assert.doesNotMatch(walletCard,/h\$\{detail\?'1':'2'\}/);
  assert.match(walletCard,/<h2>\$\{esc\(business\.name\|\|'Business'\)\} rewards<\/h2>/);
  assert.match(app,/id="walletBack" aria-label="Back to all businesses"[^>]*min-width:44px/);
  assert.match(loyalty,/if\(canManageLoyalty\)\{[\s\S]{0,300}?get_active_birthday_program/,
    'read-only staff must not call the owner-only birthday programme RPC');
});

test('mobile Retention actions wrap and navigation stays fully discoverable without horizontal scrolling',()=>{
  assert.match(retention,/class="retention-taxonomy-row"/);
  assert.match(retention,/class="retention-taxonomy-actions"/);
  assert.match(app,/\.retention-taxonomy-row\{[^}]*flex-wrap:wrap[^}]*min-width:0/s);
  assert.match(app,/\.retention-taxonomy-copy\{[^}]*flex-wrap:wrap[^}]*min-width:0/s);
  assert.match(app,/\.retention-taxonomy-actions\{[^}]*flex-wrap:wrap[^}]*min-width:0/s);
  const mobileShell=section('@media(max-width:960px){','@media(max-width:767px){');
  assert.match(mobileShell,/\.shell\{[^}]*grid-template-columns:minmax\(0,1fr\)[^}]*max-width:100vw[^}]*min-width:0/s);
  assert.match(mobileShell,/\.side\{[^}]*width:100%[^}]*max-width:100vw[^}]*min-width:0[^}]*overflow:visible/s);
  assert.match(mobileShell,/\.nav\{[^}]*display:grid[^}]*grid-template-columns:repeat\(2,minmax\(0,1fr\)\)[^}]*width:100%[^}]*min-width:0/s);
  assert.doesNotMatch(mobileShell,/overflow-x:auto|flex:0 0 max-content/);
});

test('progressive enhancement is scoped to approved customer routes',()=>{
  assert.match(app,/const customerUiRoutes=new Set\(\['till','clients','client','loyalty','retention','referrals','memberships','giftcards'\]\)/);
  assert.match(app,/if\(enhanceCustomerUi\)customerUiObserver=CUI\.mountMain\(main\)/);
});

test('customer list has search, keyboard links, pagination, export/import, and latest-response safety',()=>{
  assert.match(clients,/id="clientSearch" type="search"/);
  assert.match(clients,/CUI\.action\(\{id:'exp',label:'Export CSV'/);
  assert.match(clients,/importBtn\('customers'\)/);
  assert.match(clients,/CUI\.action\(\{id:'add',label:'Add customer'/);
  assert.match(clients,/createLatestRequestGate\(isCustomersCurrent\)/);
  assert.match(clients,/const isCurrent=customerLoadGate\.begin\(\)/);
  assert.ok((clients.match(/if\(!isCurrent\(\)\)return/g)||[]).length>=2);
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
  assert.match(giftcards,/const giftCardWorkspace=canTransact\?`/);
  assert.match(giftcards,/:`<div class="cui-card-head"><h2>Gift card transactions<\/h2>/);
  assert.match(giftcards,/if\(canTransact&&\$\('gsell'\)\)/);
  assert.match(giftcards,/if\(canTransact&&\$\('gredeem'\)\)/);
});

test('financial UI actions require module rights plus server-mirrored create-sales capability',()=>{
  assert.match(app,/owner:new Set\(\['create_sales'\]\),manager:new Set\(\['create_sales'\]\),staff:new Set\(\['create_sales'\]\)/);
  assert.match(app,/frontdesk:new Set\(\['create_sales'\]\),bookkeeper:new Set\(\)/);
  assert.match(detail,/const canWriteLoyalty=canWriteModule\('loyalty'\)&&hasRoleCapability\('create_sales'\)/);
  assert.match(memberships,/const canEnroll=canWrite&&hasRoleCapability\('create_sales'\)/);
  assert.match(giftcards,/const canTransact=canWrite&&hasRoleCapability\('create_sales'\)/);
  assert.match(till,/const canRecordSales=hasRoleCapability\('create_sales'\)&&canReadModule\('clients'\)/);
  assert.match(till,/if\(!canRecordSales\)[\s\S]*Additional access required/);
  assert.match(detail,/const canWriteLoyalty=canWriteModule\('loyalty'\)/);
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
  assert.match(clients,/if\(!isCustomersCurrent\(\)\)return;[\s\S]{0,100}if\(error\)\{saveButton\.disabled=false/);
  assert.ok((detail.match(/if\(!isClientDetailCurrent\(\)\)return/g)||[]).length>=5);
  assert.ok((till.match(/if\(!isTillCurrent\(\)\)return/g)||[]).length>=5);
  assert.ok((loyalty.match(/if\(!isLoyaltyCurrent\(\)\)return/g)||[]).length>=10);
  assert.ok((retention.match(/if\(!isRetentionCurrent\(\)\)return/g)||[]).length>=10);
  assert.match(referrals,/await sb\.rpc\('save_referral_program'[\s\S]{0,400}if\(!isReferralsCurrent\(\)\)return/);
  assert.match(memberships,/await sb\.rpc\('enroll_membership_v41'[\s\S]{0,250}if\(!isMembershipsCurrent\(\)\)return/);
  assert.match(giftcards,/await sb\.rpc\('issue_gift_card'[\s\S]{0,350}if\(!isGiftCardsCurrent\(\)\)return/);
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
