import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');

test('merchant scanner preserves classic reward redemption and distinguishes growth offers',()=>{
  assert.match(source,/function redemptionPayloadFromQr\(value,currentUrl=location\.href\)/);
  assert.match(source,/nestly:redemption:/);
  assert.match(source,/nestly:growth:/);
  assert.match(source,/growth-redeem/);
  assert.match(source,/merchant_scan_redemption_qr_v117/);
  assert.doesNotMatch(source,/sb\.rpc\('merchant_scan_redemption_qr_v89'/);
});

test('growth-offer redemption is refused before a sale and bound to the completed sale afterwards',()=>{
  assert.match(
    source,
    /payload\.kind==='growth'&&!saleId[\s\S]*Complete this customer’s purchase first/
  );
  assert.match(
    source,
    /redeem_growth_offer_v108[\s\S]*p_business:businessId,p_token:token,p_sale:saleId/
  );
  assert.match(source,/saleId:data\.sale_id\|\|null/);
  assert.match(source,/saleId:data&&data\.sale_id\|\|null/);
});

test('completed-sale receipts expose one secondary offer action while next customer remains primary',()=>{
  assert.match(source,/canScanRedemption\(\)&&doneInfo\.saleId[\s\S]*id="tRedeemOffer"/);
  assert.match(source,/canScanRedemption\(\)&&d\.saleId[\s\S]*id="tRedeemOffer"/);
  assert.match(
    source,
    /openMerchantRedemptionScanner\(\{[\s\S]*businessId:S\.biz\.id,branchId:tillBranchId,[\s\S]*saleId:doneInfo\.saleId/
  );
  assert.match(source,/<button class="btn" id="tNext"/);
  assert.match(source,/<button class="btn ghost" id="tRedeemOffer"/);
});

test('growth-offer receipt does not pretend that loyalty points were spent',()=>{
  assert.match(source,/receipt\.kind==='growth_offer'\?'':`<div><dt>Points spent/);
  assert.match(source,/receipt\.offerValueCents/);
  assert.match(source,/offerCurrency=String\(data\.currency\|\|''\)/);
  assert.doesNotMatch(source,/offerCurrency=String\(data\.currency\|\|S\.biz\?\.currency/);
  assert.match(source,/receipt\.offerValueCents&&receipt\.offerCurrency/);
  assert.doesNotMatch(source,/offerCurrency=String\([^\\n]+SGD/);
  assert.match(source,/redemption_kind:'growth_offer'/);
});

test('merchant scanner retries a lost response with the same idempotency key until terminal completion',()=>{
  const scanner=source.slice(
    source.indexOf('function openMerchantRedemptionScanner('),
    source.indexOf('function showPendingRedemptionQr(')
  );
  assert.match(scanner,/let stream=null,frameHandle=0,submitting=false,closed=false,redemptionAttempt=null/);
  assert.match(scanner,/attemptFingerprint=`\$\{payload\.kind\}:\$\{token\}:\$\{saleId\|\|''\}`/);
  assert.match(scanner,/if\(!redemptionAttempt\|\|redemptionAttempt\.fingerprint!==attemptFingerprint\)/);
  assert.match(scanner,/redemptionAttempt=\{fingerprint:attemptFingerprint,key:crypto\.randomUUID\(\)\}/);
  assert.match(scanner,/p_idempotency_key:redemptionAttempt\.key/);
  assert.match(scanner,/redemptionAttempt=null;[\s\S]*merchantRedemptionReceiptHtml\(data\)/);
  assert.doesNotMatch(scanner,/catch[\s\S]{0,300}redemptionAttempt=null/);
});
