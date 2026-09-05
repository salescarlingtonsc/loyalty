import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

/* nestly_v767 — owner rulings 2026-09-05:
   (1) a new sign-up who scanned a business QR saw "This join link is missing or invalid" over a
       join that had succeeded (two overlapping #/join renders);
   (2) a friend's referral link joins the business by itself after sign-up;
   (3) Home no longer paints the first-run "Scan a loyalty QR" card under a joined business. */
const app=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');
const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
};

test('a token-less #/join that follows a join opens that wallet instead of the missing-link error',()=>{
  const join=section('async function renderCustomerQrJoin(','async function renderCustomerClaim(');
  const fallback=join.indexOf('customerLastJoinedSlugV767()');
  const missing=join.indexOf('This join link is missing or invalid');
  assert.ok(fallback>0&&fallback<missing,'the remembered slug is consulted before the error is printed');
  /* The token is released only after the passkey prompt, so a re-entrant render replays an
     idempotent join rather than finding nothing. */
  const success=join.indexOf("joinFunnelEmitV610('join_rpc_succeeded'");
  const release=join.indexOf("rememberPendingCustomerJoinToken('')",success);
  const remember=join.indexOf('rememberCustomerLastJoinedSlugV767(slug)');
  const passkey=join.indexOf('await maybeOfferCustomerPasskeySetup({isCurrent})',success);
  assert.ok(remember>success&&remember<passkey,'the joined slug is remembered before the passkey prompt');
  assert.ok(release>passkey,'the pending token survives until after the passkey prompt');
  assert.doesNotMatch(join.slice(success,passkey),/rememberPendingCustomerJoinToken\(''\)/);
  assert.match(join.slice(success,release),/invalidatePersonaCacheV370\(\)/);
});

test('a referral link joins the business through customer_join_business_by_referral_v767',()=>{
  const helper=section('async function joinBusinessByShareReferralV767(','function peekShareReferralV576(');
  assert.match(helper,/sb\.rpc\('customer_join_business_by_referral_v767',\{/);
  assert.match(helper,/p_business_slug:cleanSlug,p_code:code/);
  assert.match(helper,/peekShareReferralV576\(cleanSlug\)/,'the code comes from the stored share referral');
  assert.match(helper,/if\(String\(error\?\.code\|\|''\)==='22023'\)\{clearShareReferralV576\(\);return '';\}/,'a permanent refusal retires the stored code');
  assert.match(helper,/rememberCustomerLastJoinedSlugV767\(/);
  /* Registration destination: join before the claim screen. */
  const destination=section('async function resolveCustomerRegistrationDestination(','/* nestly_v663 (owner photo A');
  const joined=destination.indexOf('await joinBusinessByShareReferralV767(intent)');
  const claim=destination.indexOf("nav('#/claim?business='");
  assert.ok(joined>0&&joined<claim,'the referral join runs before the claim screen is offered');
  /* Signed-in re-entry with a business intent: same order. */
  const reentry=section('async function renderCustomerRegistration(','function renderCustomerWalletUnavailable');
  const joined2=reentry.indexOf('await joinBusinessByShareReferralV767(intent)');
  const claim2=reentry.indexOf("nav('#/claim?business='");
  assert.ok(joined2>0&&joined2<claim2);
  /* Wallet: a 42501 read tries the referral join before painting "not joined". */
  const wallet=section('async function renderCustomerWallet(businessSlug=null','async function renderCustomerInAppInbox(');
  assert.equal((wallet.match(/await joinBusinessByShareReferralV767\(businessSlug\)/g)||[]).length,2,'both wallet denial branches try the referral join');
});

test('Home paints the first-run scan card only when the customer has no business at all',()=>{
  const home=section('const homeEmpty=isHome&&!homeGuidance','if(!paint(');
  assert.match(home,/&&!cards\.length/);
});

/* nestly_v777 — the referred friend sees the reward they are working towards. */
test('the pending referral reward is drawn from customer_get_referral_pending_v777 inside Points & gifts and announced once',()=>{
  const wallet=section('async function renderCustomerWallet(businessSlug=null','async function renderCustomerInAppInbox(');
  assert.match(wallet,/customerRpc\('customer_get_referral_pending_v777',\{p_business_slug:businessSlug\}\)/);
  assert.match(wallet,/<div id="walletReferralPendingV777" hidden><\/div>/,'the slot sits inside the Available panel');
  const card=section('function customerReferralPendingCardHtmlV777(','function openCustomerReferralAppliedSheetV777(');
  assert.match(card,/if\(!data\|\|data\.pending!==true\)return '';/,'nothing is drawn unless the server says pending');
  assert.match(card,/referralPendingBodyV777/);
  const apply=section('async function applyShareReferralV576(','function rememberPendingCustomerDestination(');
  assert.match(apply,/openCustomerReferralAppliedSheetV777\(data\)/,'a successful application opens the sheet');
  assert.match(apply,/toast\(ct\('joinReferralNotNewV683'\)\)/,'a 22023 refusal is no longer silent');
});
