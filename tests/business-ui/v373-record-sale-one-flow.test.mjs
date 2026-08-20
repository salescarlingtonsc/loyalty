/* V373 — Record sale becomes ONE flow (owner: "simplify my record sale, make it easy to use and
   very clear — current model too crowded and no tabs to consolidate it").

   The defect was not a control, it was the shape: three apparent transaction modes (use a
   package / record a sale / sell a package) and one column carrying every service, product,
   bundle, plan, membership, tier benefit, the cart, the price panel, the tender and the confirm
   button at the same time. These tests pin the SHAPE that replaced it, and — more importantly —
   pin that none of the money mechanics moved while it changed. */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8')
  + '\n' + readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

const till = section('async function tillPage(){', 'async function salesPage(){');
const composer = section('function drawCartComposer(){', 'async function applySvTender(){');

test('V373 the sale has two stages, and a cart in recovery can only be on the review stage', () => {
  assert.match(till, /let tillStageV373='items';/);
  // The recovery panels (stale re-price, failed finalise, live PayNow, unfinished extras) are all
  // part of the bill, so a locked cart is forced onto the stage that renders them.
  assert.match(composer, /if\(cartLocked\(\)\)tillStageV373='review';/);
  // An emptied cart can never strand the counter on a review screen with nothing to confirm.
  assert.match(composer, /if\(tillStageV373==='review'&&!cart\.length\)tillStageV373='items';/);
  // Leaving the cart step drops the stage AND the sheet, so neither can float over the keypad
  // or a receipt.
  assert.match(till, /if\(step!==2\)\{if\(tillAddSheetV373\)closeTillAddSheetV373\(\);tillStageV373='items';tillItemsTabV374='items';\}/);
  for (const marker of [
    /step=1;phone='';cust=null;walkin=false;[\s\S]{0,240}?tillStageV373='items';tillItemsTabV374='items';draw\(\);/,
    /step=1;cust=null;walkin=false;saleIdem=null;tender=null;cart=\[\];tillStageV373='items';tillItemsTabV374='items';draw\(\);/,
    /walkin=true;step=2;tillStageV373='items';tillItemsTabV374='items';/,
  ]) assert.match(till, marker);
});

test('V373 everything that is not tapped often is behind ONE tabbed sheet', () => {
  // The tabs ARE the consolidation the owner asked for: selling a package is a tab, not a journey.
  for (const label of ["{key:'services',label:'Services'}", "{key:'products',label:'Products'}",
    "{key:'usepackage',label:'Use package'}", "{key:'sellpackage',label:'Sell package'}",
    "{key:'membership',label:'Memberships'}", "{key:'custom',label:'Other item'}"])
    assert.ok(composer.includes(label), `missing sheet tab: ${label}`);
  // A tab is absent when its contents cannot exist, never present-and-broken: packages and
  // memberships are sold TO a customer, so a walk-in has neither.
  assert.match(composer, /usepackage:!walkin&&\(catalog\.customerPackages\|\|\[\]\)\.some\(item=>Number\(item\.remaining\)>0\)/);
  assert.match(composer, /const canPkg=branchCanWrite\(tillBranchId,'packages'\)&&!walkin;/);
  assert.match(composer, /const canMem=branchCanWrite\(tillBranchId,'memberships'\)&&!walkin;/);
  // Custom prices stay owner/manager only — the server enforces it, the UI must not offer it.
  assert.match(composer, /const canCustomLine=S\.myRole==='owner'\|\|S\.myRole==='manager';/);
  // The main screen keeps a bounded number of tiles plus one door to everything else.
  assert.match(till, /const TILL_QUICK_ITEMS_V373=8;/);
  assert.match(composer, /id="tAddItemV373"/);
  assert.match(composer, /if\(\$\('tAddItemV373'\)\)\$\('tAddItemV373'\)\.onclick=\(\)=>openTillAddSheetV373\(\);/);
});

test('V373 the sheet and the page share ONE binder, so a tile behaves the same wherever it is', () => {
  // The sheet is mounted on document.body, outside the route the redraw replaces, so its tiles
  // must be re-bound after every repaint. One binder, called from both places — never a second
  // copy of the handlers that could drift.
  assert.match(composer, /function bindTillControlsV373\(\)\{/);
  assert.equal((composer.match(/bindTillControlsV373\(\);/g) || []).length, 2,
    'the binder is called from the composer render and the sheet repaint, and nowhere else');
  assert.equal((till.match(/document\.querySelectorAll\('\[data-add\]'\)/g) || []).length, 1);
  assert.equal((till.match(/document\.querySelectorAll\('\[data-plan\]'\)/g) || []).length, 1);
  // Two focus traps on screen at once is how a keyboard user gets stuck: the custom-price dialog
  // replaces the sheet rather than stacking on it.
  assert.match(composer, /\$\('tCustomOpen'\)\.onclick=\(\)=>\{closeTillAddSheetV373\(\);openCustomModal\(\)\}/);
});

test('V373 only rewards that can be given today are shown, and the automatic one is not a button', () => {
  /* evaluate_checkout (V370) applies exactly ONE tier discount by itself: the best UNLIMITED
     discount_pct the customer's rung entitles them to. A Give button beside that one asked staff
     to hand over a discount the bill had already taken off, and burned an issue record for a
     benefit with no limit to count it against. The client must read the engine's rule, not
     invent its own. */
  assert.match(composer, /function tillAutoTierDiscountV373\(benefits\)\{/);
  assert.match(composer, /benefits\.filter\(benefit=>benefit\.benefit_kind==='discount_pct'&&benefit\.limit_count==null\)/);
  assert.match(composer, /\.sort\(\(a,b\)=>Number\(b\.discount_percent\|\|0\)-Number\(a\.discount_percent\|\|0\)\)\[0\]\|\|null;/);
  // The automatic one is reported, never offered.
  assert.match(composer, /Applied automatically at payment — no action needed/);
  // Only what a human actually hands over keeps a Give button, and only while it is claimable.
  assert.match(composer, /const giveNow=allBenefits\.filter\(benefit=>benefit\.claimable_now!==false&&benefit!==autoBenefit\);/);
  assert.match(composer, /data-tier-benefit-give-v365="\$\{esc\(benefit\.benefit_id\)\}"/);
  // The figure shown beside it is the SERVER's applied effect, never a percentage worked out here.
  assert.match(composer, /\.find\(effect=>effect&&effect\.source==='tier_benefit'&&!effect\.suppressed&&!effect\.suppression_reason\)/);
  assert.doesNotMatch(composer, /discount_percent\s*\/\s*100/);
  // The rest of the ladder is explainable on demand rather than crowding the sale.
  assert.match(composer, /function openTillAllBenefitsV373\(\)\{/);
  assert.match(composer, /Birthday month only/);
  assert.match(composer, /Used up/);
});

test('V373 the cart is always in view and quotes only figures the price check returned', () => {
  assert.match(composer, /function tillStickyCartHtmlV373\(\)\{/);
  assert.match(app, /\.till-sticky-cart-v373\{position:sticky;bottom:0;/);
  // Every payable figure is the evaluation's. The item count is the ONLY number this bar derives.
  assert.match(composer, /amount=money\(\(svTender\?svTender\.remaining_due_cents:evalResult\.total_cents\)\+extrasTotalCents\(\)\);/);
  assert.match(composer, /saved=`You save \$\{money\(evalResult\.discount_total_cents\)\}`/);
  // While the server is still pricing, the bar says so instead of showing a stale total.
  assert.match(composer, /amount='Checking price…';/);
  assert.match(composer, /amount='Price check expired';/);
});

test('V373 changed the screen, not the money: every write path and guard is intact', () => {
  // The two-step kernel journey and its single stable finalise key.
  assert.match(till, /sb\.rpc\('evaluate_checkout'/);
  assert.match(till, /sb\.rpc\('record_cart_sale'/);
  assert.match(till, /p_idempotency_key:finaliseKey/);
  assert.match(till, /clearWriteAttempt\(FINALISE_SLOT\);/);
  // Extras keep their own server-idempotent writers and their own keys.
  assert.match(till, /sb\.rpc\('sell_package_v102'/);
  assert.match(till, /use_package_session_v102/);
  // Attribution still reaches the server from the same picker, with the same default.
  assert.match(composer, /const staffPickerV287=tillAttributableStaff\.length>1/);
  assert.match(till, /p_branch:tillBranchId,p_staff:tillSaleStaffId\|\|tillStaffId,p_method:tender/);
  // A branch change still clears the cart, the catalogue and any stored PayNow request —
  // and now also closes the sheet, whose tiles belong to the branch that is going away.
  assert.match(composer, /closeTillAddSheetV373\(\);\n\s*cart=\[\];catalog=null;catalogError=null;clearCheckoutState\(\{abandon:true\}\);/);
  // The client still never prices anything: no local total, no local discount.
  assert.doesNotMatch(composer, /total_cents\s*[-+*]\s*discount/);
  // Points are the server's answer at finalise time; this screen must not preview a number
  // evaluate_checkout does not return.
  assert.match(composer, /Points are worked out when the sale is recorded/);
});

test('V374 the three sections are three tabs, and only the selected one renders', () => {
  /* Owner: "The latest version removed the transaction choices but now renders Services,
     Products, Packages and all Diamond benefits vertically on one page, causing endless
     scrolling." The sections are the same sections; what changed is that exactly one of them
     is on screen at a time. */
  assert.match(till, /let tillItemsTabV374='items';/);
  assert.match(composer, /\{key:'items',label:'Items',count:0\}/);
  assert.match(composer, /\{key:'packages',label:'Packages',count:packagesReady\}/);
  /* V399 (owner, photos 2 and 3): the tab is LABELLED "Rewards" now — it holds point gifts,
     welcome and bring-back offers and vouchers as well as tier benefits. The state key stays
     'benefits', which is what the panel selector below and every reader of tillItemsTabV374
     still switch on, so the rename is copy only. */
  assert.match(composer, /\{key:'benefits',label:'Rewards',count:rewards\.count\}/);
  // ONE panel is chosen — the other two are never concatenated underneath it.
  assert.match(composer, /const panel=active==='packages'\?tillPackagesPanelHtmlV374\(\)\s*\n\s*:active==='benefits'\?tillBenefitsPanelHtmlV374\(rewards\)\s*\n\s*:tillItemsPanelHtmlV374\(\);/);
  assert.match(composer, /<div class="till-stage-panel-v374">\$\{panel\}<\/div>/);
  // The cart bar is outside the panel, so it survives every tab.
  assert.match(composer, /\$\{cart\.length\?tillStickyCartHtmlV373\(\)/);
  assert.ok(composer.indexOf('till-stage-panel-v374') < composer.indexOf('cart.length?tillStickyCartHtmlV373()'),
    'the sticky cart must sit outside and after the tab panel');
  // Default is Items, and every fresh sale returns to it.
  assert.match(till, /let tillItemsTabV374='items';/);
  assert.match(composer, /if\(!tabs\.some\(tab=>tab\.key===tillItemsTabV374\)\)tillItemsTabV374='items';/);
  // A walk-in has neither packages nor rewards, so it gets no tabs at all rather than two dead ones.
  assert.match(composer, /\.filter\(tab=>!\(walkin&&tab\.key!=='items'\)\)/);
});

test('V374 each tab carries only its own contents, and the counts come from the same rules', () => {
  const items = section('function tillItemsPanelHtmlV374(){', 'function tillPackagesPanelHtmlV374(){');
  const packages = section('function tillPackagesPanelHtmlV374(){', 'function tillBenefitsPanelHtmlV374(rewards){');
  const benefits = section('function tillBenefitsPanelHtmlV374(rewards){', 'function tillStickyCartHtmlV373(){');
  // Items: services, products, and the door to the rest. No packages, no benefits.
  assert.match(items, /tillQuickGroupsHtmlV373\(shownServices,shownProducts\)/);
  assert.doesNotMatch(items, /tillOwnedPackagesBlockV373\(|tillRewardsBlockV373\(/);
  // Packages: the customer's own sessions plus ONE action that sells another, which opens the
  // sheet already on its tab rather than making the cashier find it.
  assert.match(packages, /const owned=tillOwnedPackagesBlockV373\(\);/);
  assert.match(packages, /id="tSellPackageV374"/);
  assert.match(composer, /\$\('tSellPackageV374'\)\.onclick=\(\)=>openTillAddSheetV373\('sellpackage'\)/);
  assert.doesNotMatch(packages, /tillQuickGroupsHtmlV373\(|tillRewardsBlockV373\(/);
  // Benefits: the rewards block's own answer, nothing else.
  assert.doesNotMatch(benefits, /tillQuickGroupsHtmlV373\(|tillOwnedPackagesBlockV373\(/);
  // The badge counts things that need a HAND. An automatic discount needs none, so it is excluded
  // — and the count is derived where eligibility is decided, never by a second copy of the rules.
  assert.match(composer, /const count=giveNow\.length\+\(welcomeOffer\?1:0\)\+\(bringbackOffer\?1:0\)\+\(catalog\.customerVouchers\|\|\[\]\)\.length\s*\+affordableV392\.length;/);
  assert.match(composer, /return \{html:rewards\?`<div class="till-rewards-v373">\$\{rewards\}<\/div>`:'',count\};/);
});
