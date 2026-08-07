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
  assert.doesNotMatch(merchant,/role="progressbar"/);
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
  assert.match(wallet,/p_business:businessId,p_branch:null,p_locale:'en'/);
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
  assert.match(app,/@media\(max-width:760px\)\{[\s\S]*\.customer-promotions-grid,\.promotion-editor-grid\{grid-template-columns:1fr\}/);
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
