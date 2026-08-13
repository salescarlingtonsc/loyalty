/* V301 — the owner report of 2026-08-13: "Business owners cannot set up rewards."

   The cold start was ~13 clicks through three STACKED popups (rewardAutoSetupModal →
   rewardDialogV238 → growPubModal); closing one dumped the owner on a page they had not chosen;
   drafts piled up unpublished; and the publish confirmation could DOUBLE-OPEN — openPublishFlow
   was auto-invoked through a queueMicrotask while its own button stayed enabled, so a second
   #growPubModal duplicated the first's ids and the visible dialog's buttons were wired to the
   one underneath it.

   Owner directive: "ONE page with step subtabs (Step 1 → 2 → 3 → …), select-and-Next simplicity
   a layman can complete unaided, publish at completion, no popups."

   What this file pins:
     A. The surface exists as a VIEW of Programmes, not a new route, and is owner-gated.
     B. Four steps, and every Next SAVES through the same draft RPCs the editor uses.
     C. Publish is save(active) → preview_publish_impact → publish_loyalty_config, inline.
     D. No dialog is ever inserted from the wizard.
     E. The entry points the owner actually presses now land here.
     F. Both publish flows are re-entrancy-guarded, so the double modal cannot recur. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const html = readFileSync(join(root, 'app', 'index.html'), 'utf8');

const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
};
/* The wizard is filed with the publish-diff helpers it reuses, so it sits between
   growBirthdayPendingChangesV291 and growPublishFieldRowsV170 — deliberately OUTSIDE the
   promotionsPage→growPage and growPage→Bring-back spans other suites slice on. */
const wizard = section('async function growSetupWizardV301(', 'function growPublishFieldRowsV170(');
const grow = section('async function growPage(', '/* ---------- Bring-back playbooks');
const comparison = section('async function growSetupComparisonV301(', 'async function growSetupWizardV301(');

/* ---------------- A. one page, a view of Programmes, owner-gated ---------------- */

test('V301 (a) the wizard is a real function, mounted from growPage', () => {
  assert.match(app, /async function growSetupWizardV301\(\{host,snapshot,isCurrent,startStep=1\}\)\{/);
  assert.match(grow, /growSetupWizardV301\(\{host:\$\('growSetupHostV301'\),snapshot,isCurrent:isGrowCurrent,startStep:growSetupStepV301\}\)/);
  // It reuses the snapshot growPage already read — no second load of the programme.
  assert.doesNotMatch(wizard, /growOverviewSnapshot\(/);
});

test('V301 (a) "setup" resolves as a Programmes view, and is not mistaken for a deep link', () => {
  assert.match(app,
    /const programmeView=\['overview','history','ongoing','available','settings','setup'\]\.includes\(String\(hashParam\|\|''\)\)\?String\(hashParam\):'list';/);
  // A view hash must never mount an engine surface — that crashed on the surface dictionary.
  assert.match(app,
    /const hashParamIsProgrammeView=\['overview','history','ongoing','available','settings','setup'\]\.includes/);
  // The three V271/V294 rail children keep resolving exactly as before.
  assert.match(app, /views:\[\['Overview','#\/grow\/overview','reports'\],\['List','#\/grow','menu'\],\['History','#\/grow\/history','waitlist'\]\]/);
  // The view replaces the category list rather than stacking on it.
  assert.match(app, /const growCategoryViewV271=!\['overview','history','setup'\]\.includes\(programmeView\);/);
  assert.match(grow, /programmeView==='setup'\?'Set up rewards'/);
});

test('V301 (a) #/grow/setup/review opens the wizard on its final step', () => {
  assert.match(app,
    /const growSetupStepV301=programmeView==='setup'&&String\(routedFocus\|\|''\)==='review'\?4:1;/);
});

test('V301 (a) a non-owner or a workspace without loyalty gets the read-only empty state', () => {
  assert.match(grow, /\$\{programmeView==='setup'\?\(canSetupGrow\s*\r?\n?\s*\?'<div id="growSetupHostV301"><\/div>'\s*\r?\n?\s*:CUI\.emptyState\(/);
  assert.match(grow, /if\(programmeView==='setup'&&canSetupGrow\)\{/);
  // canSetupGrow is the module's own owner + write gate, unchanged.
  assert.match(app, /const canSetupGrow=isOwner&&canRewards&&canWriteModule\('loyalty'\);/);
});

/* ---------------- B. four steps, and every Next saves ---------------- */

test('V301 (b) the stepper renders exactly the four steps the owner named', () => {
  assert.match(app, /const GROW_SETUP_STEPS_V301=\[\[1,'Choose'\],\[2,'Earning'\],\[3,'Reward'\],\[4,'Go live'\]\];/);
  assert.match(wizard, /GROW_SETUP_STEPS_V301\.map\(\(\[number,label\]\)=>\{/);
  assert.match(wizard, /data-grow-setup-goto-v301="\$\{number\}"/);
  // Completed steps carry a tick and stay clickable; unvisited ones are not yet reachable.
  assert.match(wizard, /const done=number<state\.step,current=number===state\.step;/);
  assert.match(wizard, /const reachable=state\.visited\.has\(number\)\|\|number<state\.step;/);
  assert.match(wizard, /\$\{done\?'✓':number\}/);
  // 44px tap targets and a strip that scrolls rather than wrapping at 390px.
  assert.match(html, /\.grow-setup-step-v301\{[^}]*min-height:44px/);
  assert.match(html, /\.grow-setup-steps-v301\{[^}]*overflow-x:auto/);
});

test('V301 (b) each step Next writes through the SAME draft RPCs the editor writes through', () => {
  // One writer for the whole wizard.
  assert.match(wizard, /const saveDraft=async config=>\{/);
  assert.match(wizard, /sb\.rpc\('create_loyalty_config_draft',\{\s*\r?\n?\s*p_business:S\.biz\.id,p_based_on:state\.basedOn,p_source:'owner_setup_wizard_v301'\}\)/);
  assert.match(wizard, /sb\.rpc\('save_loyalty_config_draft',\{\s*\r?\n?\s*p_version:state\.versionId,p_config:config,p_expected_snapshot_hash:state\.snapshotHash\|\|null\}\)/);
  // The hash is refreshed from every response, so consecutive saves are not stale.
  assert.match(wizard, /state\.snapshotHash=data\?\.snapshot_hash\|\|null;/);
  // No second writer: the wizard never touches loyalty_programs or points_mode directly.
  assert.doesNotMatch(wizard, /from\('loyalty_programs'\)/);
  assert.doesNotMatch(wizard, /points_mode/);
});

test('V301 (b) step 1 persists only a CHANGED family, and never a partial fresh model', () => {
  assert.match(wizard, /const modelForFamily=\(\)=>state\.family==='stamps'\?'stamps'\s*\r?\n?\s*:\(baseModel&&baseModel!=='stamps'\?baseModel:'points_tiers'\);/);
  assert.match(wizard, /if\(model===baseModel\)return goto\(2\);/);
  assert.match(wizard, /const result=await saveDraft\(\{loyalty_model:model\}\);/);
});

test('V301 (b) step 2 mirrors the #lsave field set, minus what belongs to publishing', () => {
  assert.match(wizard, /const row=\{business_id:S\.biz\.id,kind:'points',loyalty_model:model,\s*\r?\n?\s*expiry_mode:String\(base\?\.expiry_mode\|\|'none'\)\};/);
  assert.match(wizard, /if\(model==='stamps'\)row\.stamp_per_cents=Math\.round\(state\.stampSpend\*100\);/);
  assert.match(wizard, /else row\.earn_points_per_dollar=state\.earn;/);
  // V262's stored cost-per-point pair, written for a fresh programme exactly as #lsave would.
  assert.match(wizard, /else if\(writesCostDefault\(\)\)\{row\.redeem_points=costBasis;row\.reward_credit_cents=Math\.round\(0\.01\*100\*costBasis\)\}/);
  assert.match(wizard, /const costBasis=Number\(base\?\.redeem_points\)>0\?Math\.round\(Number\(base\.redeem_points\)\):800;/);
  assert.match(wizard, /if\(model==='points_tiers'&&base\?\.tier_basis\)row\.tier_basis=String\(base\.tier_basis\);/);
  /* configuration_status and active are NOT written here — publishing owns them, and a wizard
     that set them would publish a paused programme by accident (the V258 defect). Comments are
     stripped before the check so the explanatory prose above does not satisfy it. */
  const stepTwo = wizard
    .slice(wizard.indexOf('if(state.step===2)return withBusy'), wizard.indexOf('if(state.step===3)return withBusy'))
    .replace(/\/\*[\s\S]*?\*\//g, '');
  assert.doesNotMatch(stepTwo, /configuration_status/);
  assert.doesNotMatch(stepTwo, /row\.active|active:/);
});

test('V301 (b) step 3 writes the reward through the saveReward envelope', () => {
  assert.match(wizard, /fulfillment_kind:'manual_item',active:true\}/);
  assert.match(wizard, /await saveDraft\(\{reward:payload,reward_branch_ids:\[\],reward_service_ids:\[\],reward_product_ids:\[\]\}\)/);
  // A fresh setup cannot leave step 3 with nothing customers can claim.
  assert.match(wizard, /if\(!hasForm&&!state\.rewards\.length\)\{/);
  // V293's budget → points derivation, with the same manual-override rule.
  assert.match(wizard, /pointsInput\.value=String\(Math\.max\(1,Math\.ceil\(\(budget\*100\)\/Math\.max\(1,costPerPointCents\(\)\)\)\)\)/);
  assert.match(wizard, /pointsInput\.addEventListener\('input',\(\)=>\{manualV301=true\}\);/);
  // The classic pair keeps its own sentence rather than a catalogue its engine ignores.
  assert.match(wizard, /await saveDraft\(\{redeem_points:state\.classicRedeem,reward_credit_cents:Math\.round\(state\.classicCredit\*100\)\}\)/);
  // Stamps save their target with the programme fields.
  assert.match(wizard, /await saveDraft\(\{stamp_target:state\.stampTarget\}\)/);
});

test('V301 (b) a failed save keeps the owner on the step, with a retry and their values', () => {
  assert.match(wizard, /const failStep=\(error,tail\)=>\{state\.error=`\$\{ownerErrorText\(error\)\} \$\{tail\}`;render\(\)\};/);
  assert.match(wizard, /if\(!result\.ok\)return failStep\(result\.error,'Nothing was saved\.'\);/);
  assert.match(wizard, /\?`<div class="err" role="alert">\$\{esc\(state\.error\)\}[\s\S]{0,180}?id="growSetupRetryV301">Retry<\/button>/);
  // State lives in the closure, so a re-render cannot lose a typed value.
  assert.match(wizard, /const readStepFields=\(\)=>\{/);
});

/* ---------------- C. publish at completion, inline ---------------- */

test('V301 (c) publish is save(active) → preview_publish_impact → publish_loyalty_config', () => {
  const publish = wizard.slice(wizard.indexOf("const activeResult=await saveDraft({active:"));
  assert.match(publish, /const activeResult=await saveDraft\(\{active:!state\.keepPaused\}\);/);
  assert.match(publish, /sb\.rpc\('preview_publish_impact',\{p_config_version_id:state\.versionId\}\)/);
  assert.match(publish, /sb\.rpc\('publish_loyalty_config',\{p_version:state\.versionId\}\)/);
  assert.ok(publish.indexOf('preview_publish_impact') < publish.indexOf('publish_loyalty_config'),
    'the impact check must precede the publish');
  // 42501 says who can publish, in words.
  assert.match(publish, /publishError\.code==='42501'\?'Only the owner can publish\.'/);
});

test('V301 (c) the programme defaults ON, with an explicit way to keep it paused', () => {
  assert.match(wizard, /Programme will be ON — customers start earning when you publish\./);
  assert.match(wizard, /id="growSetupPauseV301"[^>]*>[\s\S]{0,60}?Keep it paused for now/);
  assert.match(wizard, /keepPaused:false,/);
});

test('V301 (c) the acknowledgement is INLINE and gates the button, never a dialog', () => {
  assert.match(wizard, /if\(\(impact\?\.requires_confirmation===true\|\|rules\.length>0\)&&!state\.ack\)\{/);
  assert.match(wizard, /state\.needAck=true;state\.impactRules=rules;return render\(\);/);
  assert.match(wizard, /id="growSetupAckV301"/);
  // Same wording as the existing gate.
  assert.match(wizard, /I have read the changes above and want customers to get them now\./);
  assert.match(wizard, /\$\{state\.step===4&&state\.needAck&&!state\.ack\?' disabled':''\}/);
});

test('V301 (c) the change list reuses the publish gate’s own comparison helpers', () => {
  for (const helper of ['growPublishFieldRowsV170', 'growRewardPendingChangesV291',
    'growRetentionPendingChangesV291', 'growBirthdayPendingChangesV291',
    'growRewardDiffOptionsFromSnapshotV291', 'growAttachEligibilityV291', 'growAttachDraftEligibilityV291'])
    assert.match(comparison, new RegExp(helper), `the comparison must reuse ${helper}`);
  // The publish is bundle-wide, so birthday and bring-back changes are listed too.
  assert.match(comparison, /pushChange\('Birthday benefit',change\.label,change\.live,change\.pending\)/);
  assert.match(comparison, /new bring-back rule, starts when you publish/);
  // Fail-soft: an unreadable section is NAMED, never reported as "nothing changed".
  assert.match(comparison, /const unreadable=\[diff\.rewards\?'':'rewards',diff\.retention\?'':'bring-back rules',diff\.birthday\?'':'the birthday benefit'\]\.filter\(Boolean\);/);
  assert.match(wizard, /could not be read, so they are not listed here/);
});

test('V301 (c) success replaces the wizard body and offers exactly two ways on', () => {
  assert.match(wizard, /Published — customers can use this now/);
  assert.match(wizard, /<a class="btn" href="#\/grow\/overview" id="growSetupDoneV301">Back to Programmes<\/a>/);
  assert.match(wizard, /id="growSetupAddAnotherV301">Add another reward<\/button>/);
  // The published version is no longer a draft, so a further edit starts a new one.
  assert.match(wizard, /state\.published=true;state\.versionId=null;state\.snapshotHash=null;state\.basedOn=null;/);
  assert.match(wizard, /toast\('Grow changes published'\);/);
});

/* ---------------- D. no popups ---------------- */

test('V301 (d) the wizard never inserts a dialog', () => {
  assert.doesNotMatch(wizard, /class="modal/);
  assert.doesNotMatch(wizard, /insertAdjacentHTML\('beforeend'/);
  assert.doesNotMatch(wizard, /CUI\.activateDialog/);
  assert.doesNotMatch(wizard, /openRewardDialogV238/);
  assert.doesNotMatch(wizard, /confirm\(/);
  // It renders into the Programmes card, not the body.
  assert.match(wizard, /host\.innerHTML=`<section class="grow-setup-v301"/);
});

/* ---------------- E. the entries the owner presses ---------------- */

test('V301 (e) the rewards cold start no longer opens the auto-setup modal', () => {
  assert.match(grow, /if\(canSetupGrow&&!growProgrammeExistsV258&&action\.surface==='rewards'\)return nav\('#\/grow\/setup'\);/);
  const gate = grow.slice(grow.indexOf('const openGrowEditorV258=async(action)=>{'),
    grow.indexOf("document.querySelectorAll('[data-welcome-offer-edit-v215]')"));
  // The rewards branch is the wizard; openRewardsAutoSetup survives only for the Bring-back
  // cold start, which is a different engine with no wizard of its own.
  assert.ok(gate.indexOf("action.surface==='rewards'") < gate.indexOf('openRewardsAutoSetup'),
    'the rewards branch must be decided before the auto-setup fallback');
  assert.match(app, /function openRewardsAutoSetup\(/);
});

test('V301 (e) the pending point-engine cards and the bare Point system row open the wizard', () => {
  /* V302 (owner, on the shipped V301, from a workspace whose programme is PAUSED with four
     rewards: "it still showing gift card and same UI UX"). The V301 gate excluded a paused
     catalogue as "a configured programme its owner is managing" — but paused is the state a
     failed setup ATTEMPT ends in, so the one workspace that reported the bug was the one state
     the fix could not reach. Anything not LIVE is unfinished setup. Capability is preserved by
     the wizard's permanent link into the full editor, asserted here, not by withholding the
     wizard from the owner who needs it. */
  assert.match(grow, /const growSetupEntryV301=key=>canSetupGrow&&\['points','stamps'\]\.includes\(String\(key\|\|''\)\)&&!loyaltyLive;/);
  assert.match(app, /id="growSetupFullEditorV302"/);
  assert.match(app, /More reward settings<\/a>/);
  assert.match(grow, /if\(growSetupEntryV301\(tile\.dataset\.growTopicV229\)\)return nav\('#\/grow\/setup'\);/);
  assert.match(grow, /if\(growSetupEntryV301\(topic\.key\)\)return growDraftPendingId\?'Continue set up →':'Set up →';/);
  assert.match(grow, /if\(kind==='earning'&&!rewardJourney\.earning&&canSetupGrow\)return nav\('#\/grow\/setup'\);/);
  // Once the programme IS live the existing drill is untouched.
  assert.match(grow, /growTopicV229=tile\.dataset\.growTopicV229;/);
});

test('V301 (e) both unpublished-changes banners route to the wizard’s final step', () => {
  assert.match(app, /if\(growDraftBarPublish\)growDraftBarPublish\.onclick=\(\)=>nav\('#\/grow\/setup\/review'\);/);
  assert.match(app, /if\(growOverviewDraftPublish\)growOverviewDraftPublish\.onclick=\(\)=>nav\('#\/grow\/setup\/review'\);/);
  // The old review page is NOT deleted — the studio rule builder still links it.
  assert.match(app, /function openProtectedGrowPublishReview\(draftVersionId\)\{/);
  assert.match(app, /async function studioPublishReviewPage\(routeMain,isCurrent,draftVersionId\)\{/);
  assert.match(app, /nav\(`#\/studio\/\$\{draftVersionId\}`\)/);
  // ...and the wizard's own step 4 replaces the banner on that page, so there is one door.
  assert.match(grow, /const growUnpublishedMarkerV198=growDraftPendingId&&canRewards&&programmeView!=='setup'/);
});

/* ---------------- F. the double publish modal cannot recur ---------------- */

test('V301 (f) the Grow publish flow is re-entrancy guarded and disables its trigger', () => {
  const review = section('async function studioPublishReviewPage(', 'async function studioPage(');
  assert.match(review, /let growPublishFlowBusyV301=false;/);
  assert.match(review, /if\(growPublishFlowBusyV301\|\|document\.getElementById\('growPubModal'\)\)return;/);
  assert.match(review, /const releaseV301=\(\)=>\{/);
  // The trigger stays disabled for the whole queued auto-open, not just for the RPC inside it.
  assert.match(review, /const growPublishTriggerV301=\$\('growPublishReview'\);/);
  assert.match(review, /if\(growPublishTriggerV301\)\{growPublishTriggerV301\.disabled=true;growPublishTriggerV301\.setAttribute\('aria-busy','true'\)\}/);
  assert.match(review, /queueMicrotask\(async\(\)=>\{await comparisonReadyV258;if\(isCurrent\(\)\)openPublishFlow\(\)\}\);/);
  // Closing the dialog is what re-enables it.
  assert.match(review, /const close=\(\)=>\{if\(deactivate\)deactivate\(\);else \$\('growPubModal'\)\?\.remove\(\);releaseV301\(\)\};/);
});

test('V301 (f) the Studio rule builder’s publish flow carries the same guard', () => {
  assert.match(app, /let studioPublishFlowBusyV301=false;/);
  assert.match(app, /if\(studioPublishFlowBusyV301\|\|document\.getElementById\('studioPubModal'\)\)return;/);
  assert.match(app, /const studioPublishTriggerV301=\$\('studioPublish'\);/);
  assert.match(app, /function renderPublishImpactDialog\(impact,releaseTriggerV301=\(\)=>\{\}\)\{/);
  assert.match(app, /const close=\(\)=>\{if\(deactivate\)deactivate\(\);else \$\('studioPubModal'\)\?\.remove\(\);releaseTriggerV301\(\);\};/);
});

/* ---------------- housekeeping ---------------- */

test('V301 the wizard styles ship with the page and hold at 390px', () => {
  assert.match(html, /\.grow-setup-v301\{/);
  assert.match(html, /\.grow-setup-options-v301\{display:grid;grid-template-columns:repeat\(auto-fit,minmax\(200px,1fr\)\)/);
  assert.match(html, /\.grow-setup-input-v301\{[^}]*min-height:44px/);
  assert.match(html, /@media \(max-width:520px\)\{\s*\r?\n?\s*\.grow-setup-v301\{padding:4px 10px 16px\}/);
});
