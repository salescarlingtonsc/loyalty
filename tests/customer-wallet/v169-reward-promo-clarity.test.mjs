import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
};
const rewards=section('const loadRewards=async()=>','const activityState={items:[],nextCursor:null}');
const promotion=section('function customerPromotionCardV104','function openCustomerPromotionDetailsV104');
const homeOffer=section('function customerHomeOfferMarkupV167','function customerHomeOffersMarkupV167');

test('rewards are shown under the balance that pays for them, with the steps said once',()=>{
  /* v195: the reward list renders inside the Reward points tab, which prints the balance in full.
     The card that repeated it — and the three-step strip above it — is what the owner crossed
     out. The balance is still the thing a reward is read against, so it is still asserted, on the
     tab that now owns it, and the instruction survives as one line. */
  assert.match(rewards,/rewardBalance=Math\.max\(0,Number\(loyalty\.balance\)\|\|0\)/);
  assert.match(app,/<p class="customer-programme-balance"><b>\$\{esc\(balance\)\}<\/b>/);
  assert.match(rewards,/Pick a reward, then show its QR at the counter/);
  assert.doesNotMatch(rewards,/<ol class="wallet-reward-steps"/);
  assert.doesNotMatch(rewards,/<b>3<\/b> Staff scans — points used/);
  assert.match(rewards,/CUI\.icon\('scan'/,'the redeem control still carries its QR pictogram');
  assert.doesNotMatch(app,/\.wallet-reward-steps/,'the step strip CSS went with the strip');
});

test('a reward short of points shows computed progress with an accessible text equivalent',()=>{
  assert.match(rewards,/short=r\.availability==='insufficient_balance'/);
  assert.match(rewards,/gap=Math\.max\(0,cost-rewardBalance\)/);
  assert.match(rewards,/progress=cost>0\?Math\.min\(100,Math\.max\(0,Math\.round\(\(rewardBalance\/cost\)\*100\)\)\):100/);
  assert.match(rewards,/<div class="wallet-reward-progress" aria-hidden="true" style="--reward-progress:\$\{progress\}%">/);
  assert.match(rewards,/\$\{esc\(customerPointTotalV103\(gap\)\)\} more \$\{esc\(rewardUnit\)\}/);
  assert.match(rewards,/<span class="sr-only">\$\{esc\(customerPointTotalV103\(rewardBalance\)\)\} of \$\{esc\(customerPointTotalV103\(cost\)\)\}/);
  // V176 put the tier-lock line first ("Reach Gold to unlock"), with the availability label
  // remaining as the fallback — which is exactly the secondary-text role this asserts.
  assert.match(rewards,/\$\{esc\(rewardLockLineV176\(r\)\|\|availability\[r\.availability\]\|\|'Ask at counter'\)\}/,
    'the existing availability label must remain as secondary text');
  assert.match(app,/\.wallet-reward-progress span\{[^}]*width:var\(--reward-progress,0%\)/s);
});

test('a redeemable reward is chipped Ready and keeps the QR redemption contract',()=>{
  assert.match(rewards,/ready=!!\(r\.action_key&&customerRewardCanRedeem\(r,redemptionEnabled\)\)/);
  assert.match(rewards,/\$\{ready\?'<span class="pill ok">Ready<\/span>':''\}/);
  assert.match(rewards,/data-customer-redeem="\$\{esc\(r\.action_key\)\}"><span>Show QR at counter<\/span>|data-customer-redeem="\$\{esc\(r\.action_key\)\}">\$\{CUI\.icon\('scan',\{size:17\}\)\}<span>Show QR at counter<\/span>/);
  assert.match(rewards,/button\.querySelector\('span'\)\.textContent='Show QR at counter'/);
  assert.match(rewards,/customer_create_redemption_intent_v89/);
  assert.doesNotMatch(rewards,/Redeem now/);
});

test('promotion cards surface the offer facts hook and never render a broken media area',()=>{
  assert.match(promotion,/facts\?`<p class="customer-promotion-card-facts">\$\{esc\(facts\)\}<\/p>`:''/);
  assert.match(promotion,/customer-promotion-card-media--fallback/);
  assert.match(promotion,/initial=\(String\(business\?\.name\|\|item\?\.name\|\|'P'\)\.trim\(\)\[0\]\|\|'P'\)\.toUpperCase\(\)/);
  assert.match(promotion,/data-promotion-id="\$\{esc\(item\?\.id\|\|''\)\}"/);
  assert.match(promotion,/customerPromotionCtaV104\(item,business,bookingEnabled\)/);
  assert.match(promotion,/data-promotion-status/);
  assert.match(app,/\.customer-promotion-card-media--fallback\{[^}]*aspect-ratio:21\/9/s);
  assert.match(app,/\.customer-promotion-card-media img\{[^}]*object-fit:contain/s);
});

test('the Home offer shelf is image-forward, snap-scrolling, and keeps its tracking attributes',()=>{
  assert.match(homeOffer,/customer-home-offer-media--fallback/);
  assert.match(homeOffer,/<div class="customer-home-offer-media"><img src="\$\{esc\(image\)\}"/);
  assert.match(homeOffer,/data-home-offer data-offer-id="\$\{esc\(item\?\.id\|\|''\)\}" data-offer-version="\$\{esc\(versionId\)\}"/);
  assert.match(homeOffer,/customer-offer-new/);
  assert.match(homeOffer,/customer-offer-urgent/);
  assert.match(app,/\.customer-home-offers-track\{[^}]*scroll-snap-type:x mandatory/s);
  assert.match(app,/\.customer-home-offer\{[^}]*flex:0 0 min\(78vw,320px\)/s);
  assert.match(app,/\.customer-home-offer\{[^}]*scroll-snap-align:start/s);
  assert.match(app,/\.customer-home-offer-media\{[^}]*aspect-ratio:16\/9/s);
});

test('new promotion and reward surfaces stay on theme tokens instead of hardcoded light colours',()=>{
  const tokenised=[
    // v195 removed the step strip; the reward list's own surfaces carry the same rule.
    /\.customer-programme-rewards\{[^}]*border-top:1px solid var\(--hair\)/s,
    /\.wallet-reward-progress\{[^}]*background:var\(--hair\)/s,
    /\.customer-home-offer-media--fallback\{[^}]*linear-gradient\(135deg,var\(--tint\),var\(--card\)\)/s
  ];
  for(const pattern of tokenised)assert.match(app,pattern);
});
