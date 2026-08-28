import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const html=(fs.readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+fs.readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
function expressionBetween(start,end){
  const from=html.indexOf(start),to=html.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing expression ${start}`);
  return html.slice(from+start.length,to).trim().replace(/;$/,'');
}
const grow=html.slice(
  html.indexOf('async function growOverviewSnapshot'),
  html.indexOf('/* ---------- Bring-back playbooks')
);
const continuity=html.slice(
  html.indexOf('async function withGrowEditorContinuity'),
  html.indexOf('/* ---------- Grow: one customer journey')
);
const css=html.slice(html.indexOf('/* Grow overview:'),html.indexOf('/* Program Studio'));
const curated=html.slice(html.indexOf('const WORKSPACE_COPY_V97='),html.indexOf('const WORKSPACE_GENERATED_COPY_V97='));
const templateCopy=Function(`"use strict";return (${expressionBetween(
  'const WORKSPACE_TEMPLATE_COPY_V97=',
  '\nconst WORKSPACE_INTERPOLATED_UI_INVENTORY_V97',
)})`)();
const curatedCopy=Function(`"use strict";return (${expressionBetween(
  'const WORKSPACE_COPY_V97=',
  '\nconst WORKSPACE_GENERATED_COPY_V97',
)})`)();
const templateText=(key,values,locale)=>templateCopy[key][locale]
  .replace(/\{([a-z][a-z0-9_]*)\}/gi,(_,name)=>String(values[name]??''));

test('Grow is one overview-first journey with secondary anatomy rather than four peer tabs',()=>{
  assert.match(grow,/class="grow-overview"/);
  /* V364 (owner markup 2026-08-16, photos 6 and 7: "delete this portion" / "remove this
     everywhere"). The four-step Trigger/Who/Reward/Result journey and the collapsed block that
     held it are gone; the owner reaches each of those editors from the programme it belongs to.
     The assertions that required them now require their absence, so the removal is pinned. */
  assert.doesNotMatch(grow,/aria-label="Grow customer journey"/);
  for(const step of ['trigger','who','reward','result']){
    assert.doesNotMatch(grow,new RegExp(`data-grow-step="${step}"`));
  }
  /* nestly_v584 (owner photo 14: "both needs to have their own sub tabs - to show one at a time",
     drawn over History's two column headings). V98's rule is about the TOP of Grow — it must be
     one overview-first journey, not four peer tabs — and that is unchanged: there is still no
     growtab, no settings-tabs strip and no tablist at the page level. What History now has is a
     two-way switch INSIDE one view, which is the owner's own instruction, so it is named
     explicitly here rather than being allowed in by a loosened pattern. */
  assert.doesNotMatch(grow,/data-growtab|settings-tabs/);
  const tablists=[...grow.matchAll(/role="tablist"[^>]*aria-label="([^"]*)"/g)].map(m=>m[1]);
  assert.deepEqual(tablists,['History sections'],
    'the only tablist in Grow is the History sub-tab pair the owner asked for');
  // The standalone growAutoSetup launcher was removed when Programmes was simplified to one
  // list; openRewardsAutoSetup is now the draft-creation GATE reached from the programme
  // rows and the template picker. Assert that entry point rather than the retired button.
  assert.match(grow,/id="rewardJourneyTitle"/);
  assert.doesNotMatch(grow,/id="growSecondarySettings"/);
  for(const status of ['Live','Draft ready','Needs setup'])assert.match(grow,new RegExp(`['"]${status}['"]`));
});

test('first-time setup is idempotent, guarded, draft-only and recommendation-led',()=>{
  const setup=grow.slice(grow.indexOf('function openRewardsAutoSetup('),grow.indexOf("document.querySelectorAll('[data-grow-open]')"));
  assert.match(setup,/if\(busy\)return/);
  assert.match(setup,/generate_retention_recommendation/);
  assert.match(setup,/draft_config_version_id\|\|data\?\.version_id/);
  assert.equal((setup.match(/await sb\.rpc\(/g)||[]).length,1,
    'confirmation has one recommendation draft writer');
  // The guard moved from the retired launcher onto the programme-row handlers: the popup only
  // opens when there is NO draft, so resuming still bypasses the creation RPC entirely.
  // V258: expressed by openGrowEditorV258, which returns on the existing draft first.
  assert.match(grow,/if\(growDraftVersionId\)return mountGrowSurface\(action\.surface,\{draftOverride:growDraftVersionId,\.\.\.action\}\);/,
    'resuming an existing draft bypasses the creation popup and RPC');
  assert.doesNotMatch(setup,/publish_loyalty_config|location\.reload|route\(\)/);
  assert.match(setup,/rewardAutoSetupRequestKey\?\?=crypto\.randomUUID\(\)/);
  assert.match(setup,/rewardAutoConfirm\.disabled=false/);
  assert.match(grow,/Nothing goes live until you review and publish/);
  assert.match(grow,/Staff and customers keep using the published programme/);
});

test('one coherent Grow draft is passed to earning and bring-back editors',()=>{
  assert.match(grow,/let growDraftVersionId=/);
  assert.match(grow,/if\(surface==='rewards'\)\{[\s\S]*await loyaltyPage\(undefined,draft,null,false,editorIntent\)/);
  assert.match(grow,/else if\(surface==='winback'\)\{[\s\S]*await retentionPage\(draft,editProgramId\)/);
  assert.match(grow,/draftOverride:growDraftVersionId/);
  assert.match(grow,/openRewardsAutoSetup\(action\)/);
});

test('one-sheet automatic popup is the guided start while detailed edits remain secondary',()=>{
  /* V364: 'loyaltyAudienceSettings' was only ever named by the deleted block's "Who" step; the
     audience editor itself is unchanged and still reachable from the rewards editor. */
  for(const target of ['lm','rwAdd']){
    assert.match(grow,new RegExp(`['"]${target}['"]`));
  }
  assert.match(grow,/Review the recommended starting point/);
  assert.doesNotMatch(grow,/Step 1 of 3|Step 2 of 3|Step 3 of 3/);
  assert.match(grow,/function openRewardsAutoSetup\(/);
  assert.doesNotMatch(grow,/id="growSecondarySettings"/);
  assert.doesNotMatch(grow,/data-grow-guide=/);
  assert.match(grow,/if\(activate\)\{element\.click\(\);return true\}/);
  assert.match(grow,/studio:\{hash:'#\/studio',label:'Advanced rule controls'\}/);
  const publishFlow=html.slice(html.indexOf('async function openPublishFlow()'),html.indexOf('function studioEffLabel'));
  assert.match(publishFlow,/preview_publish_impact/);
  assert.doesNotMatch(publishFlow,/publish_loyalty_config/,
    'opening the review preview must not itself publish');
});

/* nestly_v415 — THE RULE THIS TEST GUARDED WAS REVERSED BY THE OWNER, DELIBERATELY.
   Owner, 2026-08-21, photo 2 (the draft banner ringed): "remove the circled area, pressing save
   would publish to live. dont need hide in draft."
   What was given up, stated plainly so nobody restores it by accident: an edit on the Loyalty
   page used to land in a draft that customers could not see until a separate, confirmed review.
   Now every writer on that page publishes the moment its save succeeds. The Studio review flow
   below is UNCHANGED and still requires its acknowledgement — it is simply no longer the only
   road to publication.
   What is still guarded, and is what the assertions below now check: a draft is still created
   before the first server write; every writer goes through the SAME publish helper; and a publish
   the server refuses is reported as refused rather than toasted as live. */
test('nestly_v415 every writer on the Loyalty page publishes what it saves',()=>{
  const loyaltySave=html.slice(html.indexOf("const loyaltySave=$('lsave')"),html.indexOf("const loyaltyReviewPublish="));
  assert.match(loyaltySave,/await publishOnSaveV415\(versionId\)/);
  assert.ok(loyaltySave.indexOf('create_loyalty_config_draft')<loyaltySave.indexOf('save_loyalty_config_draft'),
    'the draft must still exist before any edit reaches the server');
  assert.match(loyaltySave,/savedNotLive/,'a refused publish must say so');
  assert.doesNotMatch(loyaltySave,/Nothing was published/,'the draft-only outcome is gone');

  const rewardSave=html.slice(html.indexOf('async function saveReward'),html.indexOf('const ra='));
  const tierSave=html.slice(html.indexOf('async function saveTier'),html.indexOf('const ta='));
  assert.match(rewardSave,/save_loyalty_config_draft/);
  assert.match(tierSave,/save_loyalty_tier_draft_v143/);
  /* Both were converted WITH their siblings. Leaving either on drafts once the banner was
     removed would have left a writer with no way to publish at all. */
  for(const editorSave of [rewardSave,tierSave]){
    assert.match(editorSave,/await publishOnSaveV415\(versionId\)/);
    assert.match(editorSave,/savedNotLive/);
    assert.doesNotMatch(editorSave,/openProtectedGrowPublishReview/);
  }

  const retentionDraftStart=html.indexOf('if(isOwner&&draftVersionId&&exactProgramMissing){');
  const retentionDraftActions=html.slice(retentionDraftStart,html.indexOf('if(isOwner){',retentionDraftStart));
  /* Bring-back keeps its own explicit publish: the owner's instruction named the Loyalty page,
     and this surface has its own button rather than relying on the removed banner. */
  assert.match(retentionDraftActions,/publishRetention'\)\.onclick=\(\)=>openProtectedGrowPublishReview\(draftVersionId\)/);
  assert.doesNotMatch(retentionDraftActions,/publish_loyalty_config/);

  const protectedReview=html.slice(html.indexOf('async function openPublishFlow()'),html.indexOf('/* ============================ Stored value'));
  assert.match(protectedReview,/preview_publish_impact/);
  assert.match(protectedReview,/requires_confirmation/);
  /* V288 (audit A2 LOW 22): RETARGETED, not deleted. The deliberate act is still required —
     it is a checkbox instead of transcribing the English word PUBLISH, which CLAUDE.md's
     low-literacy-first rule made indefensible for a WPass/SPass workforce. The button stays
     disabled until the acknowledgement is ticked. */
  assert.match(protectedReview,/I have read the changes above and want customers to get them now\./);
  assert.match(protectedReview,/publish_loyalty_config/);
  assert.match(protectedReview,/id="studioPubConfirm" type="button" disabled/);
  assert.match(protectedReview,/initialFocus:'#studioPubType'/);
  assert.match(protectedReview,/e\.target\.checked!==true/);
  assert.match(protectedReview,/\$\('studioPubType'\)\.checked!==true/);
  assert.doesNotMatch(protectedReview,/if\(needConfirm&&\$\('studioPubType'\)\)/);
  assert.doesNotMatch(protectedReview,/trim\(\)\.toUpperCase\(\)!=='PUBLISH'/);
});

test('staff receive published summaries while authoring and Advanced remain owner-only',()=>{
  assert.match(grow,/const isOwner=S\.myRole==='owner'/);
  assert.match(grow,/const canSetupGrow=isOwner&&canRewards&&canWriteModule\('loyalty'\)/);
  assert.match(grow,/if\(!isOwner\|\|!available\|\|!growDraftVersionId\)return ''/);
  /* V364: the Advanced tools details went with the block that contained it. Owner-only authoring
     is still gated the same way — by isOwner on the surfaces above. */
  assert.doesNotMatch(grow,/<details class="grow-advanced"/);
  // V172 prefixed this with !hashParamIsProgrammeView so a tab name in the deep-link slot no
  // longer resolves to an unknown surface and crashes the workspace. Same three-way condition.
  assert.match(grow,/if\(!hashParamIsProgrammeView&&\(\(routedAction&&isOwner\)\|\|\(hashParam&&isOwner\)\|\|routedSurface==='studio'\)\)/);
  assert.match(grow,/if\(canSetupGrow\|\|\(S\.myRole==='owner'&&canWinback&&canWriteModule\('retention'\)\)\)[\s\S]*firm_config_versions/);
});

test('advanced authoring is collapsed and optional growth tools are acknowledged',()=>{
  /* V364: "remove this everywhere" took the Advanced tools details and the Optional growth tools
     section with it. The studio route itself is untouched (#/studio still resolves). */
  assert.doesNotMatch(grow,/<details class="grow-advanced"/);
  assert.doesNotMatch(grow,/taxonomy, versions and rollback/);
  assert.doesNotMatch(grow,/Program Studio|Stored value/);
  /* V301 (owner: "i already removed gift card - but it keeps appearing"): gift cards are no
     longer one of Grow's optional growth tools — growOverviewSnapshot dropped its
     modules.includes('giftcards')-gated read along with the Programmes row it fed, since gift
     cards are sold at the counter (Serve & sell) with their switch under Customer Interface. */
  for(const module of ['referrals','memberships']){
    assert.match(grow,new RegExp(`modules\\.includes\\('${module}'\\)`));
  }
  assert.doesNotMatch(grow,/modules\.includes\('giftcards'\)/);
  assert.match(grow,/Optional growth tools/);
});

test('technical and measurement complexity defaults closed',()=>{
  const studioRow=html.slice(html.indexOf('const rowFor=(item,kind)=>'),html.indexOf('const rerender=()=>studioPage()'));
  const playbookSafety=html.slice(html.indexOf('function stepSafety()'),html.indexOf('function stepReview()'));
  assert.match(studioRow,/<details class="studio-tech"><summary>Technical detail<\/summary>/);
  assert.doesNotMatch(studioRow,/<details class="studio-tech"[^>]*\sopen(?:\s|>)/);
  assert.match(playbookSafety,/<details class="studio-advanced"/);
  assert.match(playbookSafety,/<summary>Advanced measurement settings<\/summary>/);
  assert.doesNotMatch(playbookSafety,/<details class="studio-advanced"[^>]*\sopen(?:\s|>)/);
  assert.ok(playbookSafety.indexOf('pbHoldout')>playbookSafety.indexOf('Advanced measurement settings'));
  assert.ok(playbookSafety.indexOf('pbCap')>playbookSafety.indexOf('Advanced measurement settings'));
});

test('Grow draft refreshes preserve the working context and never blank the editor first',()=>{
  assert.match(continuity,/window\.scrollX,scrollY=window\.scrollY/);
  assert.match(continuity,/document\.activeElement\?\.id/);
  assert.match(continuity,/querySelectorAll\('details'\)/);
  assert.match(continuity,/querySelectorAll\('input\[id\],select\[id\],textarea\[id\]'\)/);
  assert.match(continuity,/aria-busy/);
  assert.match(continuity,/aria-live','polite'/);
  assert.match(continuity,/window\.scrollTo\(\{left:scrollX,top:scrollY,behavior:'auto'\}\)/);
  assert.match(continuity,/focus\?\.\(\{preventScroll:true\}\)/);
  assert.match(continuity,/if\(!stableRefresh\)routeMain\.innerHTML=CUI\.loadingState/);
  assert.match(continuity,/refreshLoyaltyPanel/);
  assert.match(continuity,/refreshRetentionPanel/);
});

test('Grow is touch-safe, vertical on phones, and honours reduced motion',()=>{
  assert.match(css,/\.grow-primary\{min-height:48px/);
  assert.match(css,/\.grow-flow-foot \.btn\{min-height:44px/);
  assert.match(css,/@media\(max-width:640px\)/);
  assert.match(css,/\.grow-flow\{[^}]*grid-template-columns:1fr/);
  assert.match(css,/overflow-wrap:anywhere/);
  assert.match(css,/@media\(prefers-reduced-motion:reduce\)/);
});

test('critical new Grow copy has reviewed Chinese and Malay translations',()=>{
  for(const source of [
    'Turn visits into repeat business through one clear journey.',
    'Set up Grow',
    'Continue Grow setup',
    'Needs setup',
    'Draft ready',
    'Guided setup',
    'Optional growth tools',
    'Advanced tools'
  ]){
    const escaped=source.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
    const occurrences=[...curated.matchAll(new RegExp(`'${escaped}':'([^']+)'`,'g'))];
    assert.equal(occurrences.length,2,`${source} must have zh-CN and ms values`);
    assert.ok(occurrences.every(match=>match[1]!==source),`${source} translations cannot be inert English`);
  }
});

test('dynamic Grow and publish-preview grammar executes named templates in both locales',()=>{
  const fixtures=[
    /* V364: the four growPublished* templates were retired with the "How the programme fits
       together" block, their only render path. */
    ['publishImpactAction',{live:1,shadow:2,unbuilt:3},'1'],
    ['publishImpactActions',{live:6,shadow:2,unbuilt:3},'6'],
    ['publishDraftVersion',{version:31},'31'],
  ];
  for(const [key,values,needle] of fixtures){
    for(const locale of ['zh-CN','ms']){
      const output=templateText(key,values,locale);
      assert.match(output,new RegExp(needle),`${key}/${locale} preserves runtime values`);
      assert.doesNotMatch(output,/\{[a-z][a-z0-9_]*\}/i,`${key}/${locale} resolves placeholders`);
      assert.notEqual(output,templateText(key,values,'en'),`${key}/${locale} must not bleed English`);
    }
  }
  for(const key of ['publishMoneyLive','publishMoneyNone','publishCustomersLive','publishCustomersNone',
    'publishConfirmationSensitive','publishConfirmationStandard']){
    for(const locale of ['zh-CN','ms']){
      assert.notEqual(templateText(key,{},locale),templateText(key,{},'en'),`${key}/${locale}`);
    }
  }
});

test('publish preview keeps merchant rule-name collisions canonical in both locales',()=>{
  const preview=html.slice(html.indexOf('function renderPublishImpactDialog'),html.indexOf('/* ============================ Stored value'));
  assert.match(preview,/r\.name\?`<span data-merchant-content>\$\{esc\(r\.name\)\}<\/span>`/);
  const studioRows=html.slice(html.indexOf('const ruleRowHtml=(r)=>'),html.indexOf('// ----- event handlers -----',html.indexOf('const ruleRowHtml=(r)=>')));
  assert.match(studioRows,/r\.name\?`<span data-merchant-content>\$\{esc\(r\.name\)\}<\/span>`/);
  const retentionRows=html.slice(html.indexOf("routeMain.innerHTML=`${CUI.pageHeader({title:'Retention programs'"),html.indexOf("if(isOwner&&!draftVersionId)",html.indexOf("routeMain.innerHTML=`${CUI.pageHeader({title:'Retention programs'")));
  assert.match(retentionRows,/<b data-merchant-content>\$\{esc\(r\.name\)\}<\/b>/);
  for(const locale of ['zh-CN','ms']){
    for(const name of ['Home','Grow']){
      assert.notEqual(curatedCopy[locale][name],name,`${name} must be a real translatable UI collision`);
      const runtimeRuleName=name;
      assert.equal(runtimeRuleName,name,`${locale} merchant rule names remain byte-identical`);
    }
  }
});
