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

test('V156 customer home prioritises My Rewards above collapsed guidance and caps expanded summary height',()=>{
  const css=app;
  const home=section('function renderActionableWalletHome','async function renderCustomerWallet');
  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  const fallback=wallet.slice(wallet.indexOf("if(!businessSlug){"),wallet.indexOf("const args={p_business_slug:businessSlug}"));

  assert.match(css,/\.customer-home-summary-body\{[^}]*max-height:min\(30dvh,240px\);overflow:auto/s);
  assert.match(css,/@media\(max-width:720px\)\{[\s\S]*\.customer-home-summary-body\{max-height:30dvh\}/);

  assert.ok(home.indexOf('customerMyRewardsHeadingV156(cards.length)')<home.indexOf('customerProgrammeGridMarkupV96(cards)'));
  assert.ok(home.indexOf('customerProgrammeGridMarkupV96(cards)')<home.indexOf('customer-home-summary'));
  assert.doesNotMatch(home,/<details class="card customer-home-summary"[^>]*\bopen\b/);

  assert.ok(fallback.indexOf('customerMyRewardsHeadingV156(cards.length)')<fallback.indexOf('customerProgrammeGridMarkupV96(cards)'));
  assert.ok(fallback.indexOf('customerProgrammeGridMarkupV96(cards)')<fallback.indexOf('customer-home-summary'));
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
