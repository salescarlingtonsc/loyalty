import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=(readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
const vercel=JSON.parse(readFileSync(new URL('../../app/vercel.json',import.meta.url),'utf8'));

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

test('customer portal follows the stored preferred language (v293: en/zh-CN/ms)',()=>{
  const locale=section('const CUSTOMER_COPY','const CUSTOMER_PRIMARY_NAV');
  // normalize honors its argument, folds legacy 'zh' to zh-CN, and falls back to en
  assert.match(locale,/const normalizeCustomerLocale=value=>\{const v=String\(value\|\|''\)\.trim\(\);if\(v==='zh'\)return 'zh-CN';return CUSTOMER_LOCALES\.includes\(v\)\?v:'en'\}/);
  assert.match(locale,/'zh-CN':Object\.freeze/);
  assert.match(locale,/ms:Object\.freeze/);
  // the wallet reads the profile's preferred_language on load, no separate locale RPC
  assert.match(app,/customerLocale=normalizeCustomerLocale\(profile\?\.preferred_language\)/);
  assert.doesNotMatch(app,/customer_get_locale_preference_v95|customer_set_locale_preference_v95/);
  assert.match(app,/id="customerProfileLanguage"/);
});

test('programme selector precedes merchant detail and zero-programme state only offers issued-QR joining',()=>{
  const home=section('function renderActionableWalletHome','async function renderCustomerWallet');
  const first=section('function renderCustomerFirstProgrammeQuest','function customerProgrammeGridMarkupV96');
  // The zero-programme guard now lives in renderCustomerProgrammes, which is where the card
  // list is actually built; the invariant (no cards -> first-programme quest, and return) is
  // unchanged.
  const programmes=section('async function renderCustomerProgrammes','function renderCustomerWalletRetry');
  assert.match(programmes,/if\(!cards\.length\)\{renderCustomerFirstProgrammeQuest\(\);return\}/);
  assert.match(app,/customerProgrammeGridMarkupV96\(cards\)/);
  assert.match(app,/function customerProgrammeTileMarkupV96\([\s\S]*customer-programme-card-v95/);
  assert.match(app,/function customerProgrammeTileMarkupV96\([\s\S]*href="#\/wallet\/\$\{encodeURIComponent\(business\.slug/);
  assert.match(first,/id="customerFirstScan"/);
  assert.match(first,/ct\('qrOnlyHelp'\)/);
  // v195 added a company search to My Rewards; the ban belongs to the FIRST-PROGRAMME quest,
  // where there is by definition nothing to search, and that is the slice asserted here.
  assert.doesNotMatch(first,/customerRelationshipCheck|href="#\/claim"|type="search"/);
  assert.match(app,/id="customerProgrammeSearch" type="search"/,
    'the search the owner asked for lives on My Rewards, not on the empty state');
});

test('merchant home consumes the v95 presentation contract with truthful capability gating and resilient fallback',()=>{
  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  const presentation=section('function customerProgrammePresentationV95','function actionableWalletCardMarkup');
  assert.match(wallet,/businessId\?sb\.rpc\('customer_get_business_presentation_v95',\{p_business:businessId,p_branch:null,p_locale:customerLocale==='zh-CN'\?'zh-CN':'en'\}\)/);
  assert.match(wallet,/businessActions\?\.booking\?\.enabled===true&&presentation\.capabilities\.booking_enabled!==false/);
  assert.match(wallet,/customerMerchantExperienceMarkupV95\(\{presentation,business:b,actionableCard,programmeCards/);
  assert.match(wallet,/customerProgrammePresentationV95\(presentationResult\.error\?\{\}:presentationResult\.data/);
  assert.doesNotMatch(wallet,/customerPresentationRetry|programmeUnavailable/);
  assert.match(presentation,/customer-programme-compact-head/);
  // v194: the balance is rendered by customerProgrammeSummaryTabsV194, not the header.
  assert.match(app,/customer-programme-balance/);
  assert.doesNotMatch(presentation,/customer-merchant-hero/);
  assert.doesNotMatch(presentation,/customer-balance-panel/);
  assert.match(presentation,/customerTierHasProgressV103/);
  // v167 deliberately added a reward progress meter with an accessible text equivalent inside
  // this slice, so a blanket progressbar ban now contradicts v167. What v95 actually protects
  // is that the compact head carries no BALANCE meter — asserted above via customer-balance-panel.
  assert.doesNotMatch(presentation,/class="customer-balance-progress"/);
  assert.match(presentation,/customer-rewards-grid/);
  assert.match(presentation,/customer-perks-grid/);
  assert.match(presentation,/customer-promotions-grid/);
  /* v194 (owner: "Booking option make it smaller and put upstair"): booking is a compact action in
     the identity header, not a full-width card below the offers. Still gated on bookingEnabled. */
  assert.match(presentation,/\$\{bookingEnabled\?`<a class="btn sm customer-programme-book" href="#\/b\/\$\{encodeURIComponent\(business\.slug\|\|''\)\}"/);
  assert.doesNotMatch(presentation,/bookingEnabled\?`<section/);
  assert.doesNotMatch(presentation,/id="customerMerchantScan"/);
});

test('business media accepts only the configured public bucket object shape and CSP origin',()=>{
  const media=section('function customerMediaUrlV95','const CUSTOMER_PRIMARY_NAV');
  assert.match(media,/\/storage\/v1\/object\/public\/business-public\//);
  assert.match(media,/\(\?:logo\|hero\|programme\|reward\|product\|service\|benefit\|offer\)/);
  assert.match(media,/\(\?:png\|jpe\?g\|webp\|gif\)/);
  assert.match(media,/const origin=SB_URL\.replace/);
  assert.match(media,/return '';/);
  const csp=vercel.headers.find(header=>header.source==='/(.*)')?.headers
    ?.find(header=>header.key==='Content-Security-Policy')?.value||'';
  assert.match(csp,/img-src 'self' data: blob: https:\/\/gadpooereceldfpfxsod\.supabase\.co;/);
  assert.doesNotMatch(csp,/img-src[^;]*example\.com/);
});

test('celebration sound is opt-in, stored locally, and blocked for reduced-motion preference',()=>{
  const feedback=section('function customerConfirmedEarnFeedback','function renderCustomerFirstProgrammeQuest');
  const profile=section('async function renderCustomerProfile','async function renderCustomerQrJoin');
  assert.ok(feedback.indexOf('if(!customerCelebrationSoundEnabled)return')<feedback.indexOf('new AudioContext()'));
  assert.ok(feedback.indexOf("matchMedia?.('(prefers-reduced-motion: reduce)').matches")<feedback.indexOf('new AudioContext()'));
  assert.match(profile,/id="customerSuccessSound"/);
  assert.match(profile,/sessionStorage\.setItem\('nestly\.customer\.successSound'/);
  /* v286: the branch also rewrites the label, so match the guard rather than a one-line body. */
  assert.match(profile,/if\(reducedMotion\)\{[\s\S]{0,200}?successSound\.checked=false;successSound\.disabled=true/);
});

test('customer mobile navigation and media layouts keep accessible touch targets and stable image geometry',()=>{
  assert.match(app,/\.customer-primary-nav a,\.customer-primary-nav button:not\(\.customer-nav-scan\)\{[^}]*min-height:48px/s);
  assert.match(app,/\.customer-avatar\{[^}]*width:44px;height:44px/s);
  assert.doesNotMatch(app,/\.customer-account-menu \.customer-locale-switch/);
  assert.match(app,/\.customer-perk-card img,\.customer-offer-card img,\.customer-reward-card img\{[^}]*height:132px/s);
  assert.match(app,/@media\(max-width:720px\)\{[\s\S]*\.customer-primary-nav\{position:fixed/s);
  assert.match(app,/@media\(prefers-reduced-motion:reduce\)/);
});
