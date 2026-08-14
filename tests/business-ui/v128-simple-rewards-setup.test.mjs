import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const app=(readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
const migration=readFileSync(new URL('../../db/migrations/20260801_nestly_v128_simple_rewards_recommender.sql',import.meta.url),'utf8');
const browserFixture=readFileSync(new URL('../browser/reward-overview-owner-visual.html',import.meta.url),'utf8');
const evidence=readFileSync(new URL('../../docs/qa/evidence/V128-SIMPLE-REWARDS-SETUP.md',import.meta.url),'utf8');
const currentEvidence=readFileSync(new URL('../../docs/qa/evidence/V136-GROW-STREAMLINE.md',import.meta.url),'utf8');
const latestEvidence=readFileSync(new URL('../../docs/qa/evidence/V137-MINIMAL-AUTO-REWARDS.md',import.meta.url),'utf8');
const v138Evidence=readFileSync(new URL('../../docs/qa/evidence/V138-AUTH-GROW-CLOSURE.md',import.meta.url),'utf8');
const v139Evidence=readFileSync(new URL('../../docs/qa/evidence/V139-GROW-EDITOR-ISOLATION.md',import.meta.url),'utf8');
const v140Evidence=readFileSync(new URL('../../docs/qa/evidence/V140-GROW-DRAFT-AUTHORITY-LABEL.md',import.meta.url),'utf8');
const v281Evidence=readFileSync(new URL('../../docs/qa/evidence/V281-GROW-OVERVIEW-FIXTURE-CURRENCY.md',import.meta.url),'utf8');
/* V288: the fixture is regenerated from app/app.js on every change to it, so the doc that
   records the CURRENT hash is whichever release last re-captured it. */
const v288Evidence=readFileSync(new URL('../../docs/qa/evidence/V288-A2-GAP-CLOSURE.md',import.meta.url),'utf8');
/* V294: the owner-batch UI changes regenerated the fixture, so its provenance hash lives in the V294 evidence. */
const v294Evidence=readFileSync(new URL('../../docs/qa/evidence/V294-OWNER-BATCH-ACCEPTANCE.md',import.meta.url),'utf8');
const v295Evidence=readFileSync(new URL('../../docs/qa/evidence/V295-AUDIT-MEDIUM-CLOSURE.md',import.meta.url),'utf8');
/* V295 (owner markup 2026-08-12/13): the shared production stylesheet moved with the Customer
   360 and publish-gate fixes, so this fixture's source hash moved with it. The rule is unchanged
   — the checked-in evidence must name the exact component the fixture was built from. */
const v295FixesEvidence=readFileSync(new URL('../../docs/qa/evidence/V295-OWNER-FIXES-ACCEPTANCE.md',import.meta.url),'utf8');
/* V296 (owner markup 2026-08-12): the grow page changed again — the promotions drill, the pending
   card copy and the Points System rename — so the extracted component, and with it the fixture's
   source hash, moved again. Same rule, new release's evidence. */
const v296Evidence=readFileSync(new URL('../../docs/qa/evidence/V296-PROGRAMMES-BATCH-ACCEPTANCE.md',import.meta.url),'utf8');
const v299Evidence=readFileSync(new URL('../../docs/qa/evidence/V299-CUSTOMER-EXPERIENCE-POLISH-ACCEPTANCE.md',import.meta.url),'utf8');
const v300Evidence=readFileSync(new URL('../../docs/qa/evidence/V300-GROWTH-LOOP-ACCEPTANCE.md',import.meta.url),'utf8');
/* V301 (owner 2026-08-13: "Business owners cannot set up rewards"): the setup wizard changed
   growPage and the shared stylesheet, so the extracted component — and with it the fixture's
   source hash — moved again. Same rule, new release's evidence. */
const v301Evidence=readFileSync(new URL('../../docs/qa/evidence/V301-PROGRAMMES-SETUP-WIZARD-ACCEPTANCE.md',import.meta.url),'utf8');
/* V306: the wizard hotfix wave re-extracted growSetupWizardV301 into the shared fixture, so
   the current tree's byte identity lives in the W0 acceptance evidence. */
const v306Evidence=readFileSync(new URL('../../docs/qa/evidence/V306-W0-PROGRAMME-HOTFIXES-ACCEPTANCE.md',import.meta.url),'utf8');
const v310bEvidence=readFileSync(new URL('../../docs/qa/evidence/V310-W4B-CUSTOMER-STACK-ACCEPTANCE.md',import.meta.url),'utf8');
/* W6 increment 2 regenerated this fixture — the V313/V314 acceptance recorded it as a residual
   ("still inlines the pre-v314 wizard source"), and the switchboard rewrote the wizard it inlines.
   Wave-keyed rather than vNNN: v315-v318 are held by a parallel session. */
const w6i2Evidence=readFileSync(new URL('../../docs/qa/evidence/W6I2-PROGRAMMES-HOME-ACCEPTANCE.md',import.meta.url),'utf8');
/* V319 (owner markup 2026-08-14): the module rename, the Limited Offer child and the two-category
   Overview all landed in growPage, and the period strip moved in the shared stylesheet — so the
   extracted component, and with it this fixture's source hash, moved again. Same rule, new
   release's evidence. */
const v319Evidence=readFileSync(new URL('../../docs/qa/evidence/V319-REWARDS-AND-OFFER-ACCEPTANCE.md',import.meta.url),'utf8');
/* V322 (the six owner rulings of 2026-08-14): R6 rewrote the wizard's Programmes step into a scope
   selector, R2/R3 added the exclusivity confirmation, R5 replaced the stamp-gift screen with the
   milestone ladder and R1/R4 re-worded every referral line in points — all inside growPage and the
   wizard the extracted component inlines, so this fixture's source hash moved again. Same rule,
   new release's evidence. */
const v322Evidence=readFileSync(new URL('../../docs/qa/evidence/V322-OWNER-PROGRAMME-RULINGS-ACCEPTANCE.md',import.meta.url),'utf8');
const v324Evidence=readFileSync(new URL('../../docs/qa/evidence/V324-REWARDS-OFFER-COSMETICS-ACCEPTANCE.md',import.meta.url),'utf8');

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

const grow=section('async function growPage(','/* ---------- Bring-back playbooks');

test('Grow presents one automatic setup start followed immediately by the complete overview',()=>{
  // The standalone growAutoSetup launcher was removed when Programmes was simplified to one
  // list; openRewardsAutoSetup is now the draft-creation GATE reached from the programme
  // rows and the template picker. Assert that entry point rather than the retired button.
  /* V258 (owner item 7): the gate is now openGrowEditorV258. It still routes to
     openRewardsAutoSetup — but only for a business with no published programme, where the
     recommendation is the point. An existing programme gets its draft created implicitly. */
  assert.match(grow,/const openGrowEditorV258=async\(action\)=>\{/);
  assert.match(grow,/if\(!canSetupGrow\|\|!growProgrammeExistsV258\)return openRewardsAutoSetup\(action\);/);
  assert.ok(grow.indexOf('id="rewardJourneyTitle"')<grow.indexOf('id="growSecondarySettings"'),
    'the complete published overview must precede secondary settings');
  assert.match(grow,/<details class="grow-secondary" id="growSecondarySettings">[\s\S]*?<ol class="grow-flow"/);
  assert.match(grow,/<details class="grow-secondary" id="growSecondarySettings">[\s\S]*?Product cost and profitability/);
  assert.doesNotMatch(grow,/id="growSetupPrimary"/);
});

test('automatic setup is an accessible one-sheet review with an explicit draft-only promise',()=>{
  assert.match(grow,/function openRewardsAutoSetup\(/);
  assert.match(grow,/role="dialog"/);
  assert.match(grow,/aria-modal="true"/);
  assert.match(grow,/Review the recommended starting point/);
  assert.match(grow,/Create draft/);
  assert.match(grow,/Nothing goes live until you review and publish/);
  assert.match(grow,/Real fulfilment cost is not included/);
  assert.match(grow,/tabindex="-1"/);
  assert.match(grow,/CUI\.activateDialog\([\s\S]*?initialFocus:'#rewardAutoConfirm'/);
});

test('opening and cancelling do not write while confirm creates one idempotent recommendation draft',()=>{
  const popup=section('function openRewardsAutoSetup(','document.querySelectorAll(\'[data-reward-cost]\')');
  const beforeConfirm=popup.slice(0,popup.indexOf("sb.rpc('generate_retention_recommendation'"));
  assert.doesNotMatch(beforeConfirm,/sb\.(?:rpc|from)\([^)]*\)\.(?:insert|update|upsert|delete)/);
  assert.match(grow,/let activeSurface=null[\s\S]*?rewardAutoSetupRequestKey=null/);
  assert.match(popup,/rewardAutoSetupRequestKey\?\?=crypto\.randomUUID\(\)/);
  assert.equal((popup.match(/sb\.rpc\('generate_retention_recommendation'/g)||[]).length,1);
  assert.doesNotMatch(popup,/publish_(?:config|loyalty)|studio_publish|publishProgram/);
  // Same guard, now on the programme rows: openRewardsAutoSetup is only reached when no draft
  // exists, so an existing draft is opened rather than regenerated.
  // V258: same guarantee, expressed by the shared gate — an existing draft short-circuits
  // before any draft-creation call, so it is opened rather than regenerated.
  assert.match(grow,/if\(growDraftVersionId\)return mountGrowSurface\(action\.surface,\{draftOverride:growDraftVersionId,\.\.\.action\}\);/,
    'an existing draft must open directly instead of being replaced');
});

test('failed automatic setup remains retryable and prevents duplicate submission',()=>{
  assert.match(grow,/rewardAutoConfirm\.disabled=true/);
  assert.match(grow,/rewardAutoConfirm\.disabled=false/);
  // V183 replaced the single generic sentence with the real reason. What must hold is that a
  // failure still says nothing was published and stays retryable — not that it uses one exact
  // string. A changed-inputs conflict additionally mints a fresh idempotency key, because
  // replaying the rejected one could never succeed.
  assert.match(grow,/Nothing was published\./);
  assert.match(grow,/rewardAutoSetupRequestKey=null/);
  assert.match(grow,/Try creating draft again/);
  assert.match(grow,/aria-live="polite"/);
});

test('only a writable owner receives the automatic setup control',()=>{
  assert.match(grow,/const canSetupGrow=isOwner&&canRewards&&canWriteModule\('loyalty'\)/);
  assert.match(grow,/const canSetupGrow=isOwner&&canRewards&&canWriteModule\('loyalty'\)/);
});

test('popup and primary controls retain 44px touch targets and collapse at 390px',()=>{
  assert.match(app,/\.reward-auto-dialog[\s\S]*?max-width:/);
  assert.match(app,/\.reward-auto-actions[\s\S]*?\.btn\{min-height:44px/);
  assert.match(app,/@media\(max-width:640px\)[\s\S]*?\.reward-auto-dialog/);
});

test('server recommendation uses governed sectors and serializes stale tabs onto one editable draft',()=>{
  assert.match(migration,/app\.c45_owner_loyalty_write\(p_business\)/);
  assert.match(migration,/app\.can_module_write_at_v94\(p_business,null,'loyalty'\)/);
  assert.match(migration,/where id=p_business for update/);
  assert.match(migration,/in \('salon','spa','facial','massage','fitness','retail'\) then 'points_tiers'/);
  assert.match(migration,/'status','existing_draft'/);
  assert.match(migration,/'resumed_existing',true/);
  assert.ok(
    migration.indexOf("'status','existing_draft'")<migration.indexOf('insert into public.retention_recommendation_runs'),
    'a stale second tab must resume before a new run or draft can be inserted'
  );
  assert.doesNotMatch(migration,/publish_loyalty_config|publish_config/);
});

test('checked-in browser evidence identifies the exact extracted production component',()=>{
  const sourceHash=browserFixture.match(/name="production-source-sha256" content="([a-f0-9]{64})"/)?.[1];
  assert.ok(sourceHash,'generated browser fixture must carry its production source hash');
  assert.match(`${evidence}\n${currentEvidence}\n${latestEvidence}\n${v138Evidence}\n${v139Evidence}\n${v140Evidence}\n${v281Evidence}\n${v288Evidence}\n${v294Evidence}\n${v295Evidence}\n${v295FixesEvidence}\n${v296Evidence}\n${v299Evidence}\n${v300Evidence}\n${v301Evidence}\n${v306Evidence}\n${v310bEvidence}\n${w6i2Evidence}\n${v319Evidence}\n${v322Evidence}\n${v324Evidence}`,new RegExp(sourceHash));
});
