import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
const helperStart=app.indexOf('function promotionRpcErrorIsAmbiguousV104');
const helperEnd=app.indexOf('function promotionPreviewMarkupV104',helperStart);
assert.ok(helperStart>=0&&helperEnd>helperStart,'retry classifier must exist');
const helperSource=app.slice(helperStart,helperEnd);
const classify=new Function(`${helperSource};return promotionRpcErrorIsAmbiguousV104;`)();
const currentStart=app.indexOf('function promotionPageCurrentV104');
const currentEnd=app.indexOf('async function promotionsPage',currentStart);
assert.ok(currentStart>=0&&currentEnd>currentStart,'route-current helper must exist');
const currentSource=app.slice(currentStart,currentEnd);
const pageIsCurrent=new Function(`${currentSource};return promotionPageCurrentV104;`)();
const pageStart=app.indexOf('async function promotionsPage');
const pageEnd=app.indexOf('async function growPage',pageStart);
const page=app.slice(pageStart,pageEnd);

test('a 504 after commit keeps the exact finalization receipt and photo for replay',()=>{
  const afterCommitGatewayError={
    status:504,
    message:'Gateway timeout after upstream commit'
  };
  assert.equal(classify(afterCommitGatewayError),true);
  assert.equal(classify({status:503,message:'Service unavailable'}),true);
  assert.equal(classify({status:429,message:'Too many requests'}),true);
  /* V280 retarget: the guarantee is unchanged — an AMBIGUOUS failure must never delete the photo
     or the receipt, because Postgres may have committed. What changed is that a version conflict
     joined that set: it is definitively rolled back, but it is retryable with re-read versions and
     the retry needs the SAME uploaded photo. Deleting it there is what made a stale version an
     offer that could never be published. */
  assert.match(page,/if\(!promotionRpcErrorIsAmbiguousV104\(result\.error\)\s*&&!promotionVersionConflictV280\(result\.error\)\)\{[\s\S]*cleanFailedUpload\(pending\)[\s\S]*writeSessionValue\(pendingStorageKey,null\)/);
  assert.match(page,/The save outcome is still unconfirmed\. Check your connection, then press again\./);
});

test('definitive validation failures clean the uncommitted upload',()=>{
  assert.equal(classify({status:400,code:'23514',message:'promotion image required'}),false);
  assert.equal(classify({status:403,code:'42501',message:'owner required'}),false);
  assert.match(page,/v104 promotion photo after definitive finalization failure/);
});

test('draft edits and unpublishing use the same stable receipt path',()=>{
  assert.doesNotMatch(page,/business_save_promotion_v104/);
  assert.match(page,/business_finalize_promotion_v155/);
  assert.match(page,/operation:unpublish\?'unpublish':publish\?'publish':'draft'/);
  assert.match(page,/completionMessage=pending=>pending\?\.operation==='unpublish'/);
  assert.match(page,/promotionUnpublish'\)\.onclick=\(\)=>save\(false,\{unpublish:true\}\)/);
});

test('a delayed save response cannot repaint a route after its Promotions page is replaced',async()=>{
  const pageRoot={isConnected:true};
  const host={contains:node=>node===pageRoot};
  assert.equal(pageIsCurrent(pageRoot,host),true);
  let rendered=false;
  let resolveResponse;
  const delayed=new Promise(resolve=>{resolveResponse=resolve});
  const complete=async()=>{
    await delayed;
    if(!pageIsCurrent(pageRoot,host))return;
    rendered=true;
  };
  const pending=complete();
  pageRoot.isConnected=false;
  resolveResponse();
  await pending;
  assert.equal(rendered,false);
  assert.match(page,/isPromotionCurrent=\(\)=>S\.biz\?\.id===businessId&&promotionPageCurrentV104\(pageRoot,host\)/);
  assert.match(page,/const created=await ensureDraft\(draft\);\s*if\(created\.error\)\{\s*if\(!isPromotionCurrent\(\)\)return/);
  /* V280 retarget: `const finalized` became `let finalized` so a version conflict can be re-read
     and retried once. The staleness guard this test protects is asserted on the same await, and
     on the conflict retry that now sits between it and the error branch. */
  assert.match(page,/let finalized=await runPendingFinalize\(pendingFinalize\);/);
  assert.match(page,/const refreshed=await refreshPromotionV280\(workingPromotionId\);\s*if\(!isPromotionCurrent\(\)\)return;/);
  assert.match(page,/if\(finalized\.error\)\{\s*if\(!isPromotionCurrent\(\)\)return;/);
  assert.match(page,/if\(!isPromotionCurrent\(\)\)return;\s*const savedId=/);
});

test('an in-flight save keeps one immutable company identity across RPC, storage, cleanup, and retry state',()=>{
  assert.match(page,/const businessId=S\.biz\.id,businessName=S\.biz\.name,businessSlug=S\.biz\.slug/);
  assert.match(page,/businessSnapshot=Object\.freeze\(\{id:businessId,name:businessName,slug:businessSlug\}\)/);
  assert.match(page,/business_get_promotion_editor_v155',\{p_business:businessId\}/);
  assert.match(page,/p_business:businessId,p_promotion_id:workingPromotionId/);
  assert.match(page,/p_business:businessId,p_promotion_id:promotion\.id/);
  assert.match(page,/objectPath=`\$\{businessId\}\/offer\//);
  assert.match(page,/businessId,objectPath:oldPath/);
  assert.match(page,/businessId,\s*objectPath:pending\.objectPath/);
  assert.match(page,/nestly\.v104\.promotion-create\.\$\{businessId\}/);
  assert.match(page,/nestly\.v104\.promotion-finalize\.\$\{businessId\}/);
  assert.doesNotMatch(page.slice(page.indexOf('const createPendingStorageKey')),
    /S\.biz\.(?:id|name|slug)/);
});

/* V373 (P0 incident) — the promotion editor was the source of a runaway request loop against
   production: ~1,200 aborted transactions/sec, 854 million cumulative rollbacks tracking the
   authenticated set_config count almost 1:1, with every PostgREST session cycling
   BEGIN → set_config → business_finalize_promotion_v155 → idle in transaction (aborted) → ABORT.

   The loop was armed from RENDER. When a pending finalize receipt existed for the promotion being
   opened, promotionsPage scheduled the save itself on a zero-delay timer, with no attempt cap and
   no user interaction — and re-armed it on every re-entry to the page. A receipt the server keeps
   refusing therefore replayed for as long as the page existed.

   These tests hold the three properties that make that impossible, at the source, so the loop
   cannot be reintroduced by a later edit. */

test('V373 opening a promotion never sends a finalize by itself',()=>{
  const resumeBranch=page.slice(page.indexOf("}else if(pendingFinalize?.promotionId===workingPromotionId){"));
  assert.ok(resumeBranch,'the interrupted-save branch must still exist');
  const branch=resumeBranch.slice(0,resumeBranch.indexOf('routeDispose='));
  assert.doesNotMatch(branch,/setTimeout/,
    'render must not schedule a save — that was the loop');
  /* Every call to save() in this branch must sit inside a click handler. Strip the handler bodies
     and nothing that calls save() may be left standing at statement level, where merely opening
     the page would run it. */
  const withoutHandlers=branch.replace(/onclick=\(\)=>\{[\s\S]*?\}/g,'onclick=HANDLER');
  assert.doesNotMatch(withoutHandlers,/\bsave\(/,
    'a resume may only run from an explicit control, not from render');
  assert.match(branch,/promotionResumeFinalizeV373/,
    'the resume must be offered as a control the owner presses');
  assert.match(branch,/resumeButton\.onclick=\(\)=>\{resumeButton\.hidden=true;save\(/,
    'and pressing it must hide the control so one press is one attempt');
});

test('V373 one finalize at a time, and the trigger is disabled until it settles',()=>{
  assert.match(page,/let promotionSaveInFlightV373=false;/);
  assert.match(page,/if\(promotionSaveInFlightV373\)return;\s*\n\s*promotionSaveInFlightV373=true;/,
    'a second trigger while one is in flight must be dropped, not queued');
  assert.match(page,/promotionSaveButtonsV373\(\)\.forEach\(button=>\{button\.disabled=true\}\);/,
    'every save trigger is disabled for the duration');
  assert.match(page,/finally\{[\s\S]*promotionSaveInFlightV373=false;/,
    'the flag must clear however the save ended, or the editor locks up');
  const buttonsHelper=page.slice(page.indexOf('const promotionSaveButtonsV373='));
  for(const control of ['promotionSave','promotionPublish','promotionUnpublish','promotionResumeFinalizeV373']){
    assert.ok(buttonsHelper.slice(0,300).includes(control),`${control} must be covered by the guard`);
  }
});

test('V373 one receipt can only be sent a bounded number of times',()=>{
  assert.match(page,/const PROMOTION_FINALIZE_MAX_SENDS_V373=3;/);
  assert.match(page,/const sends=Number\(pending\?\.sendsV373\|\|0\)\+1;/);
  assert.match(page,/if\(sends>PROMOTION_FINALIZE_MAX_SENDS_V373\)\{/,
    'past the ceiling the receipt must be released, not replayed again');
  const capBlock=page.slice(page.indexOf('if(sends>PROMOTION_FINALIZE_MAX_SENDS_V373){'));
  assert.match(capBlock.slice(0,600),/pendingFinalize=null;writeSessionValue\(pendingStorageKey,null\)/,
    'the exhausted receipt is cleared so a reload cannot resume it');
  assert.match(capBlock.slice(0,600),/promotion_finalize_attempts_exhausted_v373/,
    'and the owner is told once, with a definite outcome');
  /* The count rides on the receipt, which is persisted, so a reload cannot reset the ceiling. */
  assert.match(page,/pending\.sendsV373=sends;\s*\n\s*if\(pendingFinalize===pending\)writeSessionValue\(pendingStorageKey,pending\);/);
});

test('V373 only v155 is ever called from the client',()=>{
  assert.doesNotMatch(app,/business_finalize_promotion_v154/,
    'v154 has the identical 26-argument signature and must never be called by mistake');
  const calls=[...app.matchAll(/sb\.rpc\('business_finalize_promotion_v\d+'/g)].map(m=>m[0]);
  assert.deepEqual([...new Set(calls)],["sb.rpc('business_finalize_promotion_v155'"]);
});
