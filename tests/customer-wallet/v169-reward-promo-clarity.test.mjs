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
/* nestly_v422: several removed phrases survive inside the comments that explain their removal, so
   any "this copy is gone" assertion has to read the CODE, not the prose around it. */
const rewardsCode=rewards.replace(/\/\*[\s\S]*?\*\//g,' ');
const promotion=section('function customerPromotionCardV104','function openCustomerPromotionDetailsV104');
const homeOffer=section('function customerHomeOfferMarkupV167','function customerHomeOffersMarkupV167');

test('rewards are shown under the balance that pays for them, with the steps said once',()=>{
  /* v195: the reward list renders inside the Reward points tab, which prints the balance in full.
     The card that repeated it — and the three-step strip above it — is what the owner crossed
     out. The balance is still the thing a reward is read against, so it is still asserted, on the
     tab that now owns it, and the instruction survives as one line. */
  /* nestly_v422: the list no longer measures a reward against the balance — it shows only rewards
     the server already says are claimable, so it holds no cost-versus-balance arithmetic at all.
     The balance is still printed by the Points card this list mounts inside (asserted below). */
  assert.doesNotMatch(rewardsCode,/rewardBalance/,'no balance arithmetic left on this list');
  assert.match(app,/<p class="customer-programme-balance"><b>\$\{esc\(balance\)\}<\/b>/);
  assert.match(rewards,/Pick a reward, then show its QR at the counter/);
  assert.doesNotMatch(rewards,/<ol class="wallet-reward-steps"/);
  assert.doesNotMatch(rewards,/<b>3<\/b> Staff scans — points used/);
  assert.match(rewards,/CUI\.icon\('scan'/,'the redeem control still carries its QR pictogram');
  assert.doesNotMatch(app,/\.wallet-reward-steps/,'the step strip CSS went with the strip');
});

test('nestly_v422: a reward the customer has not earned is not on this list at all',()=>{
  /* Owner photo 6 struck out, on the cards themselves: the progress bar, the "5/5 stamps ·
     0 more to go" reading and the "More points needed" line — every one of them belonging to a
     card that could not be claimed — and wrote "only show redeemable rewards after customer
     achieve the reward". So the third card type v340 built (in progress) and the tier-locked card
     v176 built are not restyled here; they are not rendered. The distance to the next reward is
     the stamp card / points figure at the top of the page, which is the picture of it.
     The bar itself is NOT dead: customerCardProgressV2B still draws it on the wallet tiles. */
  assert.doesNotMatch(rewardsCode,/inProgressV340/,'no in-progress card on this list');
  assert.doesNotMatch(rewardsCode,/customer-reward-progress-read-v340/,'no "{collected}/{cost}" reading');
  assert.doesNotMatch(rewardsCode,/more to go/,'no gap line');
  assert.doesNotMatch(rewardsCode,/rewardLockLineV176/,'no tier-locked card to label');
  assert.doesNotMatch(rewardsCode,/customer-reward-locked-v339/);
  assert.match(rewards,/const claimableRewardsV422=rewards\.filter\(item=>item\.action_key&&customerRewardCanRedeem\(item,redemptionEnabled\)\)/,
    'the one predicate that decides what appears — the same one the hero ready-count uses');
  assert.match(app,/\.wallet-reward-progress span\{[^}]*width:var\(--reward-progress,0%\)/s,
    'the meter CSS stays: the wallet tiles still draw it');
});

test('a redeemable reward is chipped Ready and keeps the QR redemption contract',()=>{
  /* nestly_v422: readiness is decided once, by the filter above, so the card no longer computes
     its own `ready` — every card on this list is a claimable one. */
  assert.match(rewards,/customerRewardCanRedeem\(item,redemptionEnabled\)/);
  /* v339 restyled the RESTING card (photo 1): the badge moved to the head of the card and reads
     "Ready to claim". It is still driven by the same `ready` expression asserted above, and the
     redemption contract below is untouched. */
  assert.match(rewards,/<span class="pill ok">Ready to claim<\/span>/);
  assert.match(rewards,/data-customer-redeem="\$\{esc\(r\.action_key\)\}"><span>Show QR at counter<\/span>|data-customer-redeem="\$\{esc\(r\.action_key\)\}">\$\{CUI\.icon\('scan',\{size:16\}\)\}<span>Show QR at counter<\/span>/);
  /* nestly_v397: the hero swipe's "Redeem now" carries the SAME data-customer-redeem contract and
     is wired by this same handler, so the handler can no longer hardcode one button's label on
     restore — it would rename the hero button to "Show QR at counter" mid-flight. Each button now
     restores the label it was rendered with. The list's own label is asserted above and the
     redemption contract below is untouched: one intent RPC, one QR sheet, two entry points. */
  assert.match(rewards,/const restoreLabelV397=button\.querySelector\('span'\)\?\.textContent\|\|''/);
  assert.match(rewards,/button\.querySelector\('span'\)\.textContent=restoreLabelV397/);
  assert.match(rewards,/\[data-hero-swipe-v395\] \[data-customer-redeem\]/,
    'the hero page button is wired by THIS handler, not a second redemption path');
  assert.match(rewards,/customer_create_redemption_intent_v89/);
  assert.equal([...rewards.matchAll(/sb\.rpc\('customer_create_redemption_intent_v89'/g)].length,1,
    'still exactly one place that mints a redemption intent');
});

test('the hero reward page offers Redeem only when the SERVER says the counter will honour it',()=>{
  /* v145 forbids browser-side reward readiness. v395 drew this page's state from balance minus
     cost, which would offer a Redeem button for a reward that is ended, tier-locked, over its
     claim limit, or belongs to a firm with redemption switched off. */
  const hero=section('function customerHeroRewardPagesV395','function customerBusinessSecondaryMarkupV346');
  assert.match(hero,/const readyV397=!!\(reward\?\.action_key&&customerRewardCanRedeem\(reward,redemptionEnabled\)\)/);
  assert.doesNotMatch(hero,/remaining===0\?'READY'/,'the pill must not be driven by arithmetic');
  assert.match(hero,/readyV397\?'READY':'NEXT REWARD'/);
  assert.match(hero,/data-customer-redeem="\$\{esc\(reward\.action_key\)\}" data-hero-redeem-v397/);
  /* The meter and the distance line survive only on a reward still being earned.
     V468-C4 (owner photo 7: "for stamps, don't need this meter bar, remove!") narrows that to a
     POINTS reward still being earned — a stamp card counts in whole stamps, which the counter
     above now states outright, so the bar was a second and vaguer telling of it. */
  assert.match(hero,/const rewardUnitV468=customerRewardUnitV429\(reward,unit\)/,
    'the unit comes from the existing v429 plumbing, not a second stamp test');
  assert.match(hero,/const stampsV468=rewardUnitV468==='stamps'/);
  assert.match(hero,/const meterV468=readyV397\|\|stampsV468\?''\s*\n\s*:`<div class="customer-reward-progress/);
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
  /* nestly_v421 (owner, photo 1: "picture not max out" / "why here have big empty space"). The
     media block carries the artwork as --offer-art as well as in the <img>, so the frame around a
     picture that does not fill it is the same picture blurred rather than empty space. */
  assert.match(homeOffer,/<div class="customer-home-offer-media has-art-v421" style="--offer-art:url\(&quot;\$\{esc\(cssUrlValueV421\(image\)\)\}&quot;\)"><img src="\$\{esc\(image\)\}"/);
  assert.match(homeOffer,/data-home-offer data-offer-id="\$\{esc\(item\?\.id\|\|''\)\}" data-offer-version="\$\{esc\(versionId\)\}"/);
  assert.match(homeOffer,/customer-offer-new/);
  assert.match(homeOffer,/customer-offer-urgent/);
  assert.match(app,/\.customer-home-offers-track\{[^}]*scroll-snap-type:x mandatory/s);
  assert.match(app,/\.customer-home-offer\{[^}]*flex:0 0 min\(78vw,320px\)/s);
  assert.match(app,/\.customer-home-offer\{[^}]*scroll-snap-align:start/s);
  /* nestly_v421: the fixed 16:9 frame is what LEFT the empty space the owner marked — it is now
     the space the copy does not use, so the picture is as large as the card allows at every
     breakpoint rather than at one. The artwork inside is still contained, never cropped. */
  assert.match(app,/\.customer-home-offer-media\{aspect-ratio:auto;flex:1 1 0%;min-height:88px\}/);
  assert.match(app,/\.customer-home-offer-media>img\{position:relative;z-index:1;object-fit:contain\}/);
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
