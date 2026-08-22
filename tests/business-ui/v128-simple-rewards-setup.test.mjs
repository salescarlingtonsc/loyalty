import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const app=(readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
const migration=readFileSync(new URL('../../db/migrations/20260801_nestly_v128_simple_rewards_recommender.sql',import.meta.url),'utf8');
const evidence=readFileSync(new URL('../../docs/qa/evidence/V128-SIMPLE-REWARDS-SETUP.md',import.meta.url),'utf8');
/* V288: the fixture is regenerated from app/app.js on every change to it, so the doc that
   records the CURRENT hash is whichever release last re-captured it. */
/* V294: the owner-batch UI changes regenerated the fixture, so its provenance hash lives in the V294 evidence. */
/* V295 (owner markup 2026-08-12/13): the shared production stylesheet moved with the Customer
   360 and publish-gate fixes, so this fixture's source hash moved with it. The rule is unchanged
   — the checked-in evidence must name the exact component the fixture was built from. */
/* V296 (owner markup 2026-08-12): the grow page changed again — the promotions drill, the pending
   card copy and the Points System rename — so the extracted component, and with it the fixture's
   source hash, moved again. Same rule, new release's evidence. */
/* V301 (owner 2026-08-13: "Business owners cannot set up rewards"): the setup wizard changed
   growPage and the shared stylesheet, so the extracted component — and with it the fixture's
   source hash — moved again. Same rule, new release's evidence. */
/* V306: the wizard hotfix wave re-extracted growSetupWizardV301 into the shared fixture, so
   the current tree's byte identity lives in the W0 acceptance evidence. */
/* W6 increment 2 regenerated this fixture — the V313/V314 acceptance recorded it as a residual
   ("still inlines the pre-v314 wizard source"), and the switchboard rewrote the wizard it inlines.
   Wave-keyed rather than vNNN: v315-v318 are held by a parallel session. */
/* V319 (owner markup 2026-08-14): the module rename, the Limited Offer child and the two-category
   Overview all landed in growPage, and the period strip moved in the shared stylesheet — so the
   extracted component, and with it this fixture's source hash, moved again. Same rule, new
   release's evidence. */
/* V322 (the six owner rulings of 2026-08-14): R6 rewrote the wizard's Programmes step into a scope
   selector, R2/R3 added the exclusivity confirmation, R5 replaced the stamp-gift screen with the
   milestone ladder and R1/R4 re-worded every referral line in points — all inside growPage and the
   wizard the extracted component inlines, so this fixture's source hash moved again. Same rule,
   new release's evidence. */
/* V331/V332 (owner: "proceed all at once" — Tiered membership, Stamp card, Memberships, Lifestyle
   bring-back): Tiers got its own page and Bring-back rules got a real delete, both changing
   growPage/retentionPage and the shared stylesheet, so the extracted component's source hash
   moved again. Same rule, new release's evidence — batched into one file for the whole arc. */
/* v333 regenerated this fixture again: the customer tier rail gained two CSS rules
   (.customer-tier-bar.is-compact, the last-marker label shift), and this fixture inlines
   app/index.html's stylesheet under the same pin. */
/* nestly_v421: the reward-overview browser fixture had stopped rendering and had drifted out of
   step with its own generator; this document carries the hash of the repaired one. V401's is left
   as it was — it is the record of what was captured then, not a value to keep current. */

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
  /* V364 (owner markup 2026-08-16, photos 6 and 7: "delete this portion" across the whole
     "How the programme fits together" / "Product cost and profitability" block, and "remove this
     everywhere" across the collapsed bar itself). The three assertions that stood here required
     that block to exist. They are replaced by their opposite rather than deleted, so the removal
     is pinned and cannot creep back: the overview is now the whole page. */
  assert.doesNotMatch(grow,/id="growSecondarySettings"/);
  assert.doesNotMatch(grow,/id="profitabilityTitle"/);
  assert.doesNotMatch(grow,/<ol class="grow-flow"/);
  assert.match(grow,/id="rewardJourneyTitle"/);
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

/* The evidence-markdown reads that fed the deleted assertion went with it: each was a
   readFileSync bound to a name nothing referenced any more, and thirty dead file reads at
   the top of a test file read as coverage that is not there. */
/* REMOVED (2026-08-22): a test that read the production-source SHA out of the checked-in
   fixture and asserted that same SHA appeared somewhere in thirty-two evidence markdown files.
   It proved only that two copies of one string matched, and it INVERTED the incentive: the
   fixture was 33 hunks behind app/app.js, and regenerating it to current source made this
   assertion FAIL, so scripts/quality/regen-visual-fixtures.mjs had to `git checkout --` the
   fixture back to stale on every run. Byte-equality against a fresh regeneration now lives in
   tests/business-ui/reward-overview-fixture-parity.test.mjs, which fails when the fixture is
   stale instead of when it is current. */
