import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
};
const merchant=section('function customerPromotionCtaV104','function actionableWalletCardMarkup');
/* V310: the blanket "no progressbar anywhere in this slice" below was written when this span was
   the merchant markup and its immediate helpers. The v310 programme stack now lives in the same
   span and carries the same V167 reward meter the v95 suite already stopped banning outright (see
   its own note there). What this assertion actually protects is that the merchant EXPERIENCE
   markup — the compact head and the sections it lays out — carries no balance meter of its own,
   so it is asserted on exactly that function instead of on everything above it. */
const merchantExperience=section('function customerMerchantExperienceMarkupV95','function actionableWalletCardMarkup');
const wallet=section('async function renderCustomerWallet','async function renderCustomerInAppInbox');

test('customer programme makes up to six promotions primary and keeps identity/points compact',()=>{
  assert.match(merchant,/customer-programme-compact-head/);
  // v194 moved the balance into the Reward points tab; v103 owns that assertion now.
  assert.match(app,/customer-programme-balance/);
  assert.match(merchant,/const offers=\(Array\.isArray\(presentation\.offers\)\?presentation\.offers:\[\]\)\.slice\(0,6\)/);
  assert.match(merchant,/customer-promotions-section/);
  assert.match(merchant,/customer-promotions-grid/);
  assert.ok(merchant.indexOf('customer-promotions-section')<merchant.indexOf('presentation.products.length'),
    'promotions must precede supporting products and services');
  assert.doesNotMatch(merchant,/customer-merchant-hero/);
  assert.doesNotMatch(merchant,/customer-balance-panel/);
  assert.doesNotMatch(merchantExperience,/role="progressbar"/);
  assert.doesNotMatch(merchant,/customer-offers-grid/,
    'a current offer must not be repeated again below products and benefits');
});

test('customer consumes the server-limited linked-business promotion projection',()=>{
  assert.match(wallet,/customer_get_promotions_v155/);
  /* V201 (owner: "customer view only have 1 company instead of multiple branch"). This used to
     pin p_branch:selectedBranchId||null. selectedBranchId is WORKSPACE state, so a staff member
     who is also a customer carried their branch scope into their own customer view and silently
     lost the other outlets' offers. The customer sees the firm; a promotion restricted to one
     outlet says so in its own terms. The v178 sheet path already read firm-wide — this is the
     wallet catching up, not a new rule. */
  assert.match(wallet,/p_business:businessId,p_branch:null,p_locale:merchantCopyLocale\(\)/);
  assert.match(wallet,/Array\.isArray\(promotionsResult\.data\?\.items\)\?promotionsResult\.data\.items:\[\]/);
  assert.match(wallet,/const programmeOffersStatus=promotionsResult\.error\?'error':'ready'/);
  assert.match(wallet,/promotionsResult\.error\s*\?\[\]/);
  assert.doesNotMatch(wallet,/businessId\?sb\.from\('business_customer_content_v95'/);
});

test('each promotion CTA has one clear, working outcome',()=>{
  assert.match(merchant,/cta=metadata\.cta\|\|\{\}/);
  assert.match(merchant,/requestedKind=String\(cta\.kind\|\|metadata\.cta_kind\|\|'programme'\)/);
  assert.match(merchant,/configured=String\(cta\.label\|\|metadata\.cta_label\|\|''\)/);
  assert.match(merchant,/kind==='book'&&bookingEnabled[\s\S]*href="#\/b\//);
  assert.match(merchant,/requestedKind==='book'&&!bookingEnabled\?'programme':requestedKind/);
  assert.match(merchant,/requestedKind==='book'&&!bookingEnabled\?'View details'/);
  assert.match(merchant,/data-promotion-counter/);
  assert.match(merchant,/data-promotion-details/);
  assert.match(wallet,/Show this offer to the team at the counter/);
  assert.match(wallet,/openCustomerPromotionDetailsV104/);
  assert.match(merchant,/customerPromotionValidityV104/);
  assert.match(merchant,/Valid \$\{starts\} – \$\{ends\}/);
  assert.match(merchant,/data-promotion-details-template/);
  assert.match(merchant,/customerPromotionDetailsModal/);
  assert.match(merchant,/CUI\.activateDialog/);
  assert.match(merchant,/loading="eager"/);
  assert.match(merchant,/alt="\$\{esc\(item\?\.image_alt\|\|item\?\.imageAlt/);
});

test('desktop and mobile promotion cards prioritize marketing without overflow or auto-rotation',()=>{
  assert.match(app,/\.customer-promotions-grid\{display:grid;grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
  /* v326 (owner: "in phone view, please put side by side to swipe, don't arrange above &
     bottom"): below 760px the customer offers row now scrolls horizontally instead of stacking
     to one column; the business-side promotion editor grid keeps its own single-column rule. */
  assert.match(app,/@media\(max-width:760px\)\{[\s\S]*\.promotion-editor-grid\{grid-template-columns:1fr\}/);
  assert.match(app,/\.customer-promotions-grid\{display:flex;grid-template-columns:none;overflow-x:auto;scroll-snap-type:x mandatory/);
  assert.match(app,/\.customer-promotion-card\{[^}]*border-radius:18px/s);
  assert.match(app,/\.customer-promotion-card-copy\{[^}]*min-width:0/s);
  assert.match(app,/\.customer-promotion-card-copy h3\{[^}]*color:#fff/s,
    'promotion headings must override the global dark heading colour on image cards');
  assert.match(app,/\.customer-promotion-card-copy h3,\.customer-promotion-card-copy p,\.customer-promotion-card-copy summary,\.customer-promotion-card-copy dd\{overflow-wrap:anywhere;word-break:break-word\}/);
  assert.match(app,/\.customer-promotion-card details\{min-width:0\}/);
  assert.match(app,/\.customer-promotion-card details\[open\]\{flex:1 1 100%;width:100%\}/);
  assert.match(app,/#customerPromotionDetailsModal h2,#customerPromotionDetailsModal p,#customerPromotionDetailsModal dd\{overflow-wrap:anywhere;word-break:break-word\}/,
    'long factual offer text must wrap in the details modal instead of clipping');
  assert.match(app,/#customerPromotionDetailsModal \.modal-card,#customerPromotionDetailsModal \.row,#customerPromotionDetailsModal h2\{min-width:0\}/);
  assert.match(app,/\.customer-programme-compact-head \.customer-programme-logo\{width:48px;height:48px/);
  assert.doesNotMatch(merchant,/setInterval|autoplay|carousel/);
});

/* -------------------------------------------------------------------------------- v286 findings */

test('the merchant studio preview is a picture of the card, not a working one',()=>{
  /* The preview renders the REAL customer card, so with CTA kind "Book now" it drew a live
     <a href="#/b/<slug>"> — a customer route. One tap took the merchant out of the workspace into
     the public booking wizard and every unsaved field of the offer they were writing was gone. */
  const preview=section('function promotionPreviewMarkupV104','function promotionPageCurrentV104');
  assert.match(preview,/<div class="promotion-preview-card" inert style="pointer-events:none">/,
    'the preview must be inert for pointer, keyboard and assistive tech alike');
  assert.match(preview,/\$\{customerPromotionCardV104\(preview,merchant,true,localPreview\)\}<\/div>/,
    'the customer card markup itself is untouched — the preview neuters it from outside');
});

test('the wallet opens the same offer sheet Home does, not a poorer second modal',()=>{
  /* One offer must not have two detail surfaces. The wallet cloned the card's own <template> —
     no artwork, no branch contact, no Book now, no Share, one dead-end "Done" — while the SAME
     offer from the Home shelf opened showCustomerOfferDetailV173 with all of it. */
  const wiring=section("document.querySelectorAll('[data-promotion-details]')",
    "document.querySelectorAll('[data-share-offer]')");
  assert.match(wiring,/\.find\(item=>String\(item\?\.id\|\|''\)===offerId\)/,
    'v265 rule: the offer is read back out of the list the page already rendered');
  assert.match(wiring,/showCustomerOfferDetailV173\(\{\.\.\.offer,business:\{\.\.\.b,id:businessId\|\|b\.id,slug:businessSlug\}\}\)/);
  assert.match(wiring,/if\(!offer\)return openCustomerPromotionDetailsV104\(card\)/,
    'a card whose offer is missing from the list still answers the tap');
  assert.match(wiring,/recordProductInteractionV100\('customer\.promotion_opened'/,
    'the v255 open event must survive the reroute');
  assert.match(wiring,/entry_point:'customer_wallet'/);
});
