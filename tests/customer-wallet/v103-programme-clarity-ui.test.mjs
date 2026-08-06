import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
};
const helperSource=section('function customerPointTotalV103','function customerMerchantExperienceMarkupV95');
const helpers=new Function(`${helperSource};return {customerPointTotalV103,customerTierHasProgressV103,customerBusinessIdV103};`)();

test('programme detail cannot disconnect or duplicate the persistent Scan QR control',()=>{
  const wallet=section('async function renderCustomerWallet','async function renderCustomerInAppInbox');
  const merchant=section('function customerMerchantExperienceMarkupV95','function actionableWalletCardMarkup');
  assert.doesNotMatch(wallet,/walletUnlink|customer_unlink_business_link|Business disconnected/);
  assert.doesNotMatch(merchant,/customerMerchantScan|ct\('addProgramme'\)/);
  assert.match(app,/id="customerNavScan"/);
  assert.match(app,/\$\('customerNavScan'\)\.onclick=openCustomerJoinScanner/);
});

test('presentation failure falls back to the loaded summary without a false programme error',()=>{
  const wallet=section('async function renderCustomerWallet','async function renderCustomerInAppInbox');
  assert.match(wallet,/customerProgrammePresentationV95\(presentationResult\.error\?\{\}:presentationResult\.data,\{business:b/);
  assert.doesNotMatch(wallet,/customerPresentationRetry|programmeUnavailable|This programme could not be loaded/);
});

test('programme balance is compact, formatted once, and tier progress is truthful',()=>{
  const merchant=section('function customerMerchantExperienceMarkupV95','function actionableWalletCardMarkup');
  const wallet=section('async function renderCustomerWallet','async function renderCustomerInAppInbox');
  assert.equal((merchant.match(/customer-programme-compact-balance/g)||[]).length,1);
  assert.match(merchant,/customerPointTotalV103\(loyalty\.balance\?\?presentation\.balance\?\?0\)/);
  assert.match(app,/\.customer-programme-compact-balance b\{[^}]*font-size:clamp\(1\.25rem,4vw,1\.65rem\)/);
  assert.equal(helpers.customerPointTotalV103(1234567),'1,234,567');
  assert.equal(helpers.customerTierHasProgressV103({}),false);
  assert.equal(helpers.customerTierHasProgressV103({progress_percent:0}),false);
  assert.equal(helpers.customerTierHasProgressV103({current:'Gold'}),true);
  assert.equal(helpers.customerTierHasProgressV103({progress_percent:25}),true);
  assert.match(merchant,/const currentTierLabel=String\(tier\.current\?\.label\|\|tier\.current\|\|tier\.label\|\|''\)\.trim\(\)/);
  assert.match(merchant,/currentTierBenefits=Array\.isArray\(tier\.current\?\.benefits\)/);
  assert.match(merchant,/hasTier&&currentTierLabel/);
  assert.doesNotMatch(merchant,/role="progressbar"/);
  assert.doesNotMatch(merchant,/customer-balance-panel/);
  assert.doesNotMatch(merchant,/Every visit still counts|ct\('noTier'\)/);
  assert.doesNotMatch(merchant,/ct\('noRewards'\)/);
  assert.doesNotMatch(wallet,/<span class="muted small">\$\{esc\(loyalty\.unit\|\|'points'\)\}/);
});

test('transactions and loyalty activity start inside one accessible collapsed History disclosure',()=>{
  const wallet=section('async function renderCustomerWallet','async function renderCustomerInAppInbox');
  assert.match(wallet,/<details class="card wallet-history-disclosure" id="walletHistoryDisclosure">/);
  assert.match(wallet,/<summary><span>History<\/span><span class="muted small">Transactions and loyalty activity<\/span><\/summary>/);
  assert.doesNotMatch(wallet,/<details class="card wallet-history-disclosure"[^>]*\bopen\b/);
  const historyStart=wallet.indexOf('id="walletHistoryDisclosure"');
  const historyEnd=wallet.indexOf('</details>',historyStart);
  assert.ok(wallet.indexOf("walletSectionShell('walletTransactions'",historyStart)<historyEnd);
  assert.ok(wallet.indexOf("walletSectionShell('walletActivity'",historyStart)<historyEnd);
});

test('each eligible reward says Show QR at counter and opens the existing pending QR flow',()=>{
  const wallet=section('async function renderCustomerWallet','async function renderCustomerInAppInbox');
  const merchant=section('function customerMerchantExperienceMarkupV95','function actionableWalletCardMarkup');
  assert.doesNotMatch(merchant,/presentation\.rewards\.map|presentation\.rewards\.length/);
  assert.match(wallet,/customerRewardCanRedeem\(r,redemptionEnabled\)[\s\S]*?<span>Show QR at counter<\/span>/);
  assert.match(wallet,/customer_create_redemption_intent_v89/);
  assert.match(wallet,/intent\?\.status!=='pending'\|\|!intent\?\.qr_token/);
  assert.match(wallet,/showPendingRedemptionQr\(\{intent,businessName:b\.name,rewardName:/);
  assert.doesNotMatch(wallet,/Ask the business to enable QR redemption|QR redemption is not enabled by this business/);
});

test('secondary programme metrics render only when they carry meaningful value',()=>{
  const wallet=section('async function renderCustomerWallet','async function renderCustomerInAppInbox');
  assert.match(wallet,/const showCreditMetric=loyalty\.enabled===true&&Number\(loyalty\.credit_balance_cents\|\|0\)>0/);
  assert.match(wallet,/const showPackageMetric=capabilities\.packages===true&&Number\(packages\.sessions_remaining\|\|0\)>0/);
  assert.match(wallet,/const showMembershipMetric=capabilities\.membership===true&&membership\.active===true/);
  assert.match(wallet,/const showSecondaryMetrics=!actionableCard&&\(showCreditMetric\|\|showPackageMetric\|\|showMembershipMetric\)/);
  assert.doesNotMatch(wallet,/membership\.active\?'Active':'Inactive'/);
});

test('successful empty Rewards and History states do not offer a misleading retry',()=>{
  const wallet=section('async function renderCustomerWallet','async function renderCustomerInAppInbox');
  const emptyTransactions=/if\(!transactionState\.items\.length\)\{([\s\S]*?)\n\s*\}/.exec(wallet)?.[1]||'';
  assert.match(emptyTransactions,/No purchases or points activity has been recorded/);
  assert.doesNotMatch(emptyTransactions,/Retry|Refresh|walletTransactionsRetry/);
  assert.match(wallet,/if\(!rewards\.length\)return walletSectionEmpty\('walletRewards'/);
  const empty=section('async function walletSectionEmpty','function renderWalletAppointments');
  assert.match(empty,/host\.remove\(\);ensureWalletEmptyState\(businessSlug\)/);
  assert.doesNotMatch(empty,/Retry|Refresh/);
});

test('UUID-only programme RPCs never receive an undefined business identifier',()=>{
  const summaryId='11111111-1111-4111-8111-111111111111';
  const actionId='22222222-2222-4222-8222-222222222222';
  const cardId='33333333-3333-4333-8333-333333333333';
  assert.equal(helpers.customerBusinessIdV103({summaryBusiness:{id:summaryId}}),summaryId);
  assert.equal(helpers.customerBusinessIdV103({actionableCard:{business:{id:actionId}}}),actionId);
  assert.equal(helpers.customerBusinessIdV103({
    businessSlug:'kopi',programmeCards:[{business:{slug:'kopi',id:cardId}}]
  }),cardId);
  assert.equal(helpers.customerBusinessIdV103({summaryBusiness:{id:'undefined'}}),null);
  const wallet=section('async function renderCustomerWallet','async function renderCustomerInAppInbox');
  assert.match(wallet,/businessId\?sb\.rpc\('customer_get_business_actions_v89',\{p_business:businessId\}\):unavailableBusinessId\(\)/);
  assert.match(wallet,/businessId\?sb\.rpc\('customer_get_business_presentation_v95',\{p_business:businessId/);
  assert.match(wallet,/customerConfirmedEarnFeedback\(businessId,next/);
  assert.doesNotMatch(wallet,/p_business:b\.id/);
});

test('programme detail keeps the notification bell linked to the dedicated Messages route',()=>{
  const wallet=section('async function renderCustomerWallet','async function renderCustomerInAppInbox');
  const shell=section('function renderCustomerShell','function focusCustomerRoute');
  const inbox=section('async function renderCustomerInAppInbox','async function renderCustomerNotificationPreferences');
  const walletBell=wallet.match(/const inboxSlot=\$\('customerInboxBellSlot'\);[\s\S]*?\n\s*}/)?.[0]||'';
  assert.match(shell,/href="#\/customer\/messages"/);
  assert.doesNotMatch(wallet,/id="customerInAppInbox"|renderCustomerInAppInbox\(businessSlug|customerNotificationPreferences|renderCustomerNotificationPreferences\(/);
  assert.match(walletBell,/href="#\/customer\/messages"/);
  assert.doesNotMatch(walletBell,/scrollIntoView/);
  assert.match(inbox,/slot\.innerHTML=`<a class="customer-inbox-bell" href="#\/customer\/messages"/);
  assert.doesNotMatch(inbox,/scrollIntoView|aria-controls="customerInAppInbox"/);
});
