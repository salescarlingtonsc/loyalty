import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
};
const page=section('async function promotionsPage','async function growPage');
const route=section('async function route','function actionableWalletExpiryText');

test('Promotions is an owner-only submodule reached from the consolidated Grow overview',()=>{
  assert.match(route,/pageKey==='promotions'&&S\.myRole!=='owner'/);
  assert.match(route,/Only the owner can publish promotions/);
  assert.match(app,/title:'Promotions',copy:'Publish a timely offer when it supports the core reward programme\.'/);
  assert.match(app,/optionalTools\.map\(tool=>[\s\S]*href="#\/\$\{tool\.key\}"/);
  assert.match(app,/>Grow<\/a>/);
  assert.match(app,/promotions:promotionsPage/);
  assert.doesNotMatch(app,/const ALLMODS=\[[^\]]*'promotions'/);
  assert.match(app,/key:'promotions'[\s\S]*title:'Promotions'/);
});

test('owner follows one factual offer, wording, photo, preview, and explicit publish flow',()=>{
  for(const id of [
    'promotionFacts','promotionOccasion','promotionStart','promotionEnd',
    'promotionPolish','promotionName','promotionMessage','promotionTerms',
    'promotionCtaKind','promotionCtaLabel','promotionImage','promotionImageAlt',
    'promotionPreview','promotionSave','promotionPublish'
  ])assert.match(page,new RegExp(`id="${id}"`));
  assert.match(page,/1\. Offer[\s\S]*2\. Message[\s\S]*3\. Publish/);
  assert.match(page,/Drafts are never shown to customers/);
  assert.match(page,/business_create_promotion_draft_v104/);
  assert.match(page,/business_finalize_promotion_v104/);
  assert.doesNotMatch(page,/business_save_promotion_v104/,
    'the compatibility writer cannot be used for draft edits or unpublishing');
  assert.match(page,/p_offer_facts:draft\.offerFacts/);
  assert.match(page,/p_occasion:draft\.occasion/);
  assert.match(page,/p_publish:publish/);
  assert.match(page,/p_promotion_id:workingPromotionId/);
  assert.match(page,/p_expected_content_version:Number\(promotion\.contentVersion\|\|0\)/);
  assert.match(page,/p_expected_copy_version:Number\(promotion\.copyVersion\|\|0\)/);
  assert.match(page,/p_name:draft\.name,p_tagline:null,p_description:draft\.description/);
  assert.match(page,/imageAlt:field\('promotionImageAlt'\)\.value\.trim\(\)/);
  assert.match(page,/\['promotionFacts','promotionOccasion','promotionEnd'\][\s\S]*applyAssistance\(false\)/);
  assert.match(page,/This offer applies across the company/);
  assert.match(page,/branch_id:null/);
  assert.doesNotMatch(page,/id="promotionBranch"/);
  assert.match(page,/id:selected\?\.id\|\|''/);
  assert.doesNotMatch(page,/id:selected\?\.id\|\|crypto\.randomUUID/);
  assert.match(page,/initial\.active\?'':`<button[^`]+id="promotionSave"/);
  assert.doesNotMatch(page,/id="promotionSave"[^>]*disabled/);
  assert.match(page,/initial\.active\?'Update published offer':'Publish offer'/);
  assert.match(page,/initial\.active\|\|Boolean\(initial\.metadata\?\.published_once_at\)\|\|canPublishNew/);
});

test('photo and copy finalize through one receipt-backed operation and preserve interrupted work',()=>{
  assert.match(page,/business_finalize_promotion_v104/);
  assert.match(page,/p_object_path:fileInfo\?\.objectPath\|\|null/);
  assert.match(page,/p_expected_target_media_version:exactTargetMediaVersion/);
  assert.match(page,/p_attempt_key:attemptKey/);
  assert.match(page,/sessionStorage\.setItem\(key,JSON\.stringify\(value\)\)/);
  assert.match(page,/nestly\.v104\.promotion-create/);
  assert.match(page,/nestly\.v104\.promotion-finalize/);
  assert.match(page,/rpcWithReceiptReplay/);
  assert.match(page,/Confirming an interrupted draft save/);
  assert.match(page,/Confirming an interrupted save/);
  assert.match(page,/NestlyMediaSyncV95\.removeOrQueue/);
  assert.match(page,/\$\{businessId\}\/offer\/\$\{crypto\.randomUUID\(\)\}\.\$\{extension\}/);
  assert.match(page,/file\.size>10485760/);
  assert.match(page,/image\/png','image\/jpeg','image\/webp','image\/gif/);
  assert.match(page,/try\{dimensions=await imageDimensionsV95\(file\)\}/);
  assert.match(page,/Photo was not saved\. Your draft is safe; try again\./);
  assert.match(page,/URL\.revokeObjectURL/);
  assert.match(page,/operation:unpublish\?'unpublish':publish\?'publish':'draft'/);
  assert.match(page,/promotionUnpublish'\)\.onclick=\(\)=>save\(false,\{unpublish:true\}\)/);
  assert.doesNotMatch(page,/else if\(!publish&&!file\)[\s\S]*rpcSavePromotion/);
  assert.match(page,/interruptedPromotionId=pendingFinalize\?\.promotionId\|\|pendingCreate\?\.promotionId/);
  assert.match(page,/Finishing the interrupted promotion save first/);
});

test('quota and recovery states are explicit without silently deleting offers',()=>{
  assert.match(page,/published_count/);
  assert.match(page,/quota_used/);
  assert.match(page,/max_published_offers/);
  assert.match(page,/launch offer slots used/);
  assert.match(page,/currently published\. Complimentary first-time publishing ends/);
  assert.match(page,/Customers see no more than two current offers at once/);
  assert.match(page,/canPublishThis=initial\.active\|\|Boolean\(initial\.metadata\?\.published_once_at\)\|\|canPublishNew/);
  assert.match(page,/max_published_offers\?\?10/);
  assert.match(page,/Publishing is not available for this company/);
  assert.match(page,/retryId:'promotionStudioRetry'/);
  assert.match(page,/Offers that are still live can still be edited or unpublished/);
  assert.match(page,/initial\.active&&initial\.imageCustomerVisible\?'Current photo is published/);
  assert.match(page,/A saved draft is not shown in your customer programme until you publish/);
  assert.doesNotMatch(page,/private photo|stays private|private draft/i);
});

test('display priority preserves a valid zero instead of silently moving the offer to the end',()=>{
  const preserved=[...page.matchAll(/Number\((?:selected\?\.|initial\.)display_order\?\?100\)/g)];
  assert.equal(preserved.length,3,'create and both finalize paths must preserve display_order 0');
  assert.doesNotMatch(page,/display_order\|\|100/);
});
