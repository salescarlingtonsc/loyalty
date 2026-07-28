import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');
const vercel=JSON.parse(readFileSync(new URL('../../app/vercel.json',import.meta.url),'utf8'));

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

test('customer locale is browser-seeded, persisted with optimistic versioning, and has English fallback',()=>{
  const locale=section('const CUSTOMER_LOCALES','const CUSTOMER_PRIMARY_NAV');
  assert.match(locale,/Object\.freeze\(\['en','zh-CN'\]\)/);
  assert.match(locale,/navigator\.languages\?\.\[0\]\|\|navigator\.language\|\|'en'/);
  assert.match(locale,/CUSTOMER_COPY\[customerLocale\]\?\.\[key\]\?\?CUSTOMER_COPY\.en\[key\]\?\?key/);
  assert.match(locale,/sb\.rpc\('customer_get_locale_preference_v95'\)/);
  assert.match(locale,/sb\.rpc\('customer_set_locale_preference_v95',\{\s*p_locale:next,p_expected_version:customerLocaleVersion/s);
  assert.match(app,/data-customer-locale="en"/);
  assert.match(app,/data-customer-locale="zh-CN"/);
  assert.match(app,/aria-pressed="\$\{customerLocale==='zh-CN'\}"/);
  assert.match(locale,/firstQuestBody:'到访参与商家时/);
});

test('programme selector precedes merchant detail and zero-programme state only offers issued-QR joining',()=>{
  const home=section('function renderActionableWalletHome','async function renderCustomerWallet');
  const first=section('function renderCustomerFirstProgrammeQuest','function renderActionableWalletHome');
  assert.match(home,/if\(!cards\.length\)\{renderCustomerFirstProgrammeQuest\(\);return\}/);
  assert.match(home,/customerProgrammeGridMarkupV96\(cards\)/);
  assert.match(app,/function customerProgrammeTileMarkupV96\([\s\S]*customer-programme-card-v95/);
  assert.match(app,/function customerProgrammeTileMarkupV96\([\s\S]*href="#\/wallet\/\$\{encodeURIComponent\(business\.slug/);
  assert.match(first,/id="customerFirstScan"/);
  assert.match(first,/ct\('qrOnlyHelp'\)/);
  assert.doesNotMatch(first,/customerRelationshipCheck|href="#\/claim"|type="search"/);
});

test('merchant home consumes the v95 presentation contract with truthful capability gating and resilient fallback',()=>{
  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  const presentation=section('function customerProgrammePresentationV95','function actionableWalletCardMarkup');
  assert.match(wallet,/sb\.rpc\('customer_get_business_presentation_v95',\{p_business:b\.id,p_branch:null,p_locale:customerLocale\}\)/);
  assert.match(wallet,/businessActions\?\.booking\?\.enabled===true&&presentation\.capabilities\.booking_enabled!==false/);
  assert.match(wallet,/customerMerchantExperienceMarkupV95\(\{presentation,business:b,actionableCard,programmeCards/);
  assert.match(wallet,/presentationResult\.error[\s\S]*customerPresentationRetry/);
  assert.match(presentation,/customer-merchant-hero/);
  assert.match(presentation,/customer-balance-panel/);
  assert.match(presentation,/role="progressbar"/);
  assert.match(presentation,/customer-rewards-grid/);
  assert.match(presentation,/customer-perks-grid/);
  assert.match(presentation,/customer-offers-grid/);
  assert.match(presentation,/bookingEnabled\?`<section/);
  assert.match(presentation,/id="customerMerchantScan"/);
});

test('business media accepts only the configured public bucket object shape and CSP origin',()=>{
  const media=section('function customerMediaUrlV95','async function loadCustomerLocaleV95');
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
  assert.match(profile,/if\(reducedMotion\)\{successSound\.checked=false;successSound\.disabled=true/);
});

test('customer mobile navigation and media layouts keep accessible touch targets and stable image geometry',()=>{
  assert.match(app,/\.customer-primary-nav a,\.customer-primary-nav button\{[^}]*min-height:48px/s);
  assert.match(app,/\.customer-avatar\{[^}]*width:44px;height:44px/s);
  assert.match(app,/\.customer-account-menu \.customer-locale-switch button\{[^}]*min-height:44px/s);
  assert.match(app,/\.customer-perk-card img,\.customer-offer-card img,\.customer-reward-card img\{[^}]*height:132px/s);
  assert.match(app,/@media\(max-width:720px\)\{[\s\S]*\.customer-primary-nav\{position:fixed/s);
  assert.match(app,/@media\(prefers-reduced-motion:reduce\)/);
});
