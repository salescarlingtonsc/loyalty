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

test('V156 customer-facing wallet labels businesses as My Rewards instead of programmes',()=>{
  const copy=section('const CUSTOMER_COPY=Object.freeze','const CUSTOMER_PRIMARY_NAV');
  assert.match(copy,/programmes:'My Rewards'/);
  assert.match(copy,/yourProgrammes:'My Rewards'/);
  assert.match(copy,/addProgramme:'Scan to join'/);
  assert.match(copy,/loadingProgrammes:'Loading My Rewards…'/);
  assert.match(copy,/merchantProgramme:'\{business\} rewards'/);
  assert.doesNotMatch(copy,/yourProgrammes:'Programmes'|programmes:'Programmes'/);
});

/* v183 (owner annotation: the whole My Rewards block struck through on Home): the reward grid
   belongs to the My Rewards tab. Home leads with offers and ends with a two-way jump-off. */
test('V183 Home leads with offers and delegates the reward grid to the My Rewards tab',()=>{
  const home=section('function renderActionableWalletHome','async function renderCustomerWallet');
  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  const fallback=wallet.slice(wallet.indexOf("if(!businessSlug){"),wallet.indexOf("const args={p_business_slug:businessSlug}"));
  const homeMarkup=home.slice(home.lastIndexOf("$('walletBody').innerHTML=`${isHome?"),home.lastIndexOf('wireCustomerHomeOffersV167(repaint)'));
  const homeBranch=homeMarkup.slice(0,homeMarkup.indexOf(':`'));

  /* v194 removed the two quick-link cards (they repeated the permanent nav). Offers are what
     Home leads with, which is the ordering this line has always been about. */
  /* v286: the guidance call moved into a `homeGuidance` const (Home now needs to know whether it
     produced anything before it decides the surface is empty). The ordering invariant is the
     rendered order, which is what this line has always been about. */
  assert.match(home,/const homeGuidance=isHome\?customerHomeGuidanceV167\(/);
  assert.ok(homeBranch.indexOf('customerHomeOffersMarkupV167(offersState)')<homeBranch.indexOf('${homeGuidance}'));
  assert.doesNotMatch(homeBranch,/customerProgrammeGridMarkupV96/,'the reward grid was crossed out on Home');
  assert.doesNotMatch(homeBranch,/customerMyRewardsHeadingV156/,'the "My Rewards" heading was crossed out on Home');
  assert.ok(homeMarkup.indexOf('customerMyRewardsHeadingV156(cards.length')<homeMarkup.indexOf('customerProgrammeGridMarkupV96(cards)'),
    'the My Rewards tab still puts its heading above its grid');

  assert.doesNotMatch(fallback,/customerHomeQuickLinksV183/);
  assert.match(fallback,/applyCustomerNavCountsV194\(\{programmes:cards\.length/,
    'the legacy Home still feeds the nav badges that replaced the quick links');
  assert.doesNotMatch(fallback,/customerProgrammeGridMarkupV96\(cards\)/,'legacy Home drops the grid too');
  assert.doesNotMatch(fallback,/Programme guidance is unavailable|<h2 style="margin:20px 0 10px">Programmes<\/h2>/);
});

test('V156 featured products and services render usable non-blank customer cards',()=>{
  const helpers=section('function customerFeaturePriceLabelV156','function showCustomerPromotionPopupV122');
  const merchant=section('function customerMerchantExperienceMarkupV95','function actionableWalletCardMarkup');

  assert.match(helpers,/function customerFeatureDurationLabelV156/);
  assert.match(helpers,/function customerFeatureTypeLabelV156/);
  assert.match(helpers,/function customerFeatureCardMarkupV156/);
  assert.match(helpers,/customer-feature-meta/);
  assert.match(merchant,/presentation\.products\.map\(item=>\(\{\.\.\.item,entity_type:item\.entity_type\|\|'product'\}\)\)/);
  assert.match(merchant,/presentation\.services\.map\(item=>\(\{\.\.\.item,entity_type:item\.entity_type\|\|'service'\}\)\)/);
  assert.match(merchant,/\.map\(customerFeatureCardMarkupV156\)\.join\(''\)/);
  assert.match(merchant,/Featured services and products will appear here after this business publishes them\./);
  assert.doesNotMatch(merchant,/\[\.\.\.presentation\.products,\.\.\.presentation\.services\]\.map\(item=>`<article class="customer-reward-card">/);
});
