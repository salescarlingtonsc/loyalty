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
  assert.match(`${evidence}\n${currentEvidence}\n${latestEvidence}\n${v138Evidence}\n${v139Evidence}\n${v140Evidence}`,new RegExp(sourceHash));
});
