/* V258 — three owner reports about the loyalty setup flow, pinned to their actual causes.
   (A, item 8) V240 hid "Lifetime points earned" whenever the combined points+tiers mode was
       selected, and silently rewrote a stored points ladder to visits, because a database
       trigger refused that pairing (23514). V256 dropped the trigger: the owner's ruling is
       that a tier is measured by LIFETIME points earned — the sum of points_ledger rows with
       entry_type='earn' — which redemption never reduces, so the two never contradict.
   (B, item 6) "published points system, but still shows paused." Publishing is NOT the bug:
       publish_loyalty_config writes `active=v_typed.active` from the draft. The draft was born
       Paused by generate_retention_recommendation, which saves 'active',false over a clone of
       the live programme, and the review screen never said so. The server half is filed as
       db/migrations/20260809_nestly_v258_recommended_draft_inherits_live_status.sql; the
       client half is the warning pinned here.
   (C, item 7) "why does edit require draft then edit?" The versioning stays — the ceremony
       goes. An owner whose programme already exists gets the draft created implicitly. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const migration = readFileSync(
  join(root, 'db', 'migrations', '20260809_nestly_v258_recommended_draft_inherits_live_status.sql'),
  'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

/* ---------------------------------- A ---------------------------------- */

test('A: lifetime points earned is a normal option in every mode', () => {
  // The gate and the silent rewrite are gone, identifier and all.
  assert.doesNotMatch(app, /tierBasisAllowsPointsV240/);
  assert.doesNotMatch(app, /tierBasisValueV240/);
  // What is stored is what is shown.
  assert.match(app, /const tierBasisValueV258=p\?\.tier_basis\|\|'visits';/);
  // The option is unconditional — no mode test wraps it any more.
  assert.match(app,
    /<option value="points_earned" \$\{tierBasisValueV258==='points_earned'\?'selected':''\}>Lifetime points earned<\/option>/);
});

test('A: the save path writes the chosen basis unchanged, and the dead 23514 branch is gone', () => {
  /* nestly_v415: the old landmark was the draft-only toast, deleted when the owner ruled that
     Save publishes (photo 2). Same handler, closing landmark moved to the publish that replaced
     it. */
  const save = section("const loyaltySave=$('lsave')", "const publishFailedV415=await publishOnSaveV415(versionId);");
  assert.match(save, /row\.tier_basis=\$\('ltb'\)\.value;/);
  assert.doesNotMatch(save, /'visits':basisV240/);
  assert.doesNotMatch(save, /basisV240/);
  // The 23514 special case was only reachable while the v239 trigger existed.
  assert.doesNotMatch(save, /modeError\.code==='23514'/);
  assert.doesNotMatch(app, /measure its tiers in points\/i\.test/);
  /* The draft save still precedes the live switch — one Save is still one decision. V314 (W6i1,
     2026-08-14): the switch became public.set_programmes_v314 on the programme spine, because
     businesses.points_mode is frozen behind a tripwire that silently pins any write to it. */
  assert.ok(save.indexOf('save_loyalty_config_draft') < save.indexOf('writeProgrammeSwitchesV314(S.biz.id,loyaltySelectionV230,'));
});

test('A: the helper line explains why the pairing is coherent', () => {
  assert.doesNotMatch(app, /Tiers count visits so points stay free to spend\./);
  assert.match(app, /Tiers count lifetime points earned — spending points never lowers a tier\./);
  // It is shown only when the basis actually is points_earned, and it is what the select
  // describes itself by.
  assert.match(app,
    /\$\{tierBasisValueV258==='points_earned'\?'<p class="muted small" id="ltbHelpV258"/);
  assert.match(app, /\$\{tierBasisValueV258==='points_earned'\?' aria-describedby="ltbHelpV258"':''\}/);
});

/* ---------------------------------- B ---------------------------------- */

test('B: publishing applies the draft status — the migration fixes where the status is lost', () => {
  /* Determination, from production: publish_loyalty_config copies the draft's own `active`
     onto loyalty_programs. The recommendation writer is what forces false over a live Active
     clone, so that is what the migration changes — and only that. */
  assert.match(migration, /publish_loyalty_config copies the draft's own flag/);
  assert.match(migration, /'kind','points','active',v_base_active,'loyalty_model',v_model,/);
  // The literal false survives only in the header that explains the bug, never in the body.
  const body = migration.split('\n').filter(line => !line.trimStart().startsWith('--')).join('\n');
  assert.doesNotMatch(body, /'active',false/);
  assert.match(migration, /select base\.active into v_base_active/);
  // A firm with no live programme still starts Paused.
  assert.match(migration, /v_base_active:=coalesce\(v_base_active,false\);/);
});

test('B: the publish review states plainly that the programme will publish paused', () => {
  const review = section('async function studioPublishReviewPage(', 'async function studioPage(');
  assert.match(review, /let draftProgrammeActiveV258=null;/);
  assert.match(review, /draftProgrammeActiveV258=draftResult\.data\?\.program\?\.active\?\?null;/);
  assert.match(review, /This will publish PAUSED — customers earn nothing\./);
  assert.match(review, /customers unable to earn points or claim rewards until you set it Active/);
  // And the fix is offered right there, as a draft-only write.
  assert.match(review, /id="growPublishActivateV258"/);
  assert.match(review,
    /sb\.rpc\('save_loyalty_config_draft',\{p_version:draftVersionId,p_config:\{active:true\}/);
  assert.match(review, /Draft Status set to Active — still nothing published/);
  assert.doesNotMatch(review.slice(review.indexOf("id=\"growPublishActivateV258\"")),
    /publish_loyalty_config'\}/, 'the activate control must never publish');
});

test('B: the confirmation cannot open before the paused state is known, and repeats it', () => {
  const review = section('async function studioPublishReviewPage(', 'async function studioPage(');
  assert.match(review, /const comparisonReadyV258=loadPublishComparison\(\);/);
  assert.match(review,
    /queueMicrotask\(async\(\)=>\{await comparisonReadyV258;if\(isCurrent\(\)\)openPublishFlow\(\)\}\);/);
  const dialog = review.slice(review.indexOf('growPubModal'));
  assert.match(dialog, /draftProgrammeActiveV258===false\?'<div class="studio-emg-banner" role="alert"/);
  assert.match(dialog, /This will publish PAUSED — customers earn nothing\./);
  /* V288 (audit A2 LOW 22): RETARGETED, not deleted. The deliberate act is still required —
     it is a checkbox instead of transcribing the English word PUBLISH, which CLAUDE.md's
     low-literacy-first rule made indefensible for a WPass/SPass workforce. The button stays
     disabled until the acknowledgement is ticked. */
  assert.match(dialog, /\$\('growPubType'\)\.checked!==true/);
});

test('B: the paused cascade stays honest — a paused programme really is unclaimable', () => {
  /* Rewards are marked unavailable from the SAME flag the server gates redemption on. V314 (W6i1,
     2026-08-14): that flag is the programme's spine row now, in both places — v314's consumers 4
     and 5 moved customer_create_redemption_intent_v89 and app.redeem_reward_core off
     loyalty_programs.active entirely (the row lookup no longer even carries `and active`), so
     reading the old column here would re-open the gap this test exists to close. */
  assert.match(app, /const programmeActive=spineAccruingV314===null\?loyalty\?\.active===true:spineAccruingV314;/);
  assert.match(app, /!loyalty\?'programme_unconfigured':!programmeActive\?'programme_paused'/);
  /* V271 removed the sentence the owner struck. The cascade is still visible, and now says WHICH
     kind of off each reward is: "Paused with programme" is the reward-level readout of this flag. */
  assert.match(app, /milestone\.availability==='programme_paused'\?\['Paused with programme','off'\]/);
});

/* ---------------------------------- C ---------------------------------- */

test('C: an existing programme opens the editor without the create-draft dialog', () => {
  const grow = section('async function growPage(', '/* ---------- Bring-back playbooks');
  assert.match(grow, /const growProgrammeExistsV258=Boolean\(snapshot\.currentVersion&&snapshot\.loyalty\);/);
  assert.match(grow, /const openGrowEditorV258=async\(action\)=>\{/);
  // Existing draft: straight in, no creation call at all.
  assert.match(grow,
    /if\(growDraftVersionId\)return mountGrowSurface\(action\.surface,\{draftOverride:growDraftVersionId,\.\.\.action\}\);/);
  // Existing programme, no draft: the draft is created implicitly from the LIVE version.
  assert.match(grow,
    /sb\.rpc\('create_loyalty_config_draft',\{\s*\n\s*p_business:S\.biz\.id,p_based_on:snapshot\.currentVersion,p_source:'owner_editor'\}\);/);
  // Every entry point uses the one gate; none of them still hand-rolls the old guard.
  /* V303 (owner 2026-08-13: "pressing add rewards - still brings me to this page"): the reward
     template picker was the third caller and now hands its chosen template to the setup wizard's
     inline form instead of to the deep editor's New-reward dialog. The rule this line guards —
     every entry point uses the ONE gate, none hand-rolls the old guard — is unchanged for the
     callers that still open the editor. */
  assert.equal((grow.match(/openGrowEditorV258\(action\)\.catch\(fail\)/g) || []).length, 2);
  assert.doesNotMatch(grow, /if\(!growDraftVersionId\)\{openRewardsAutoSetup\(action\);return\}/);
});

test('C: the dialog survives only for the path it is actually about', () => {
  const grow = section('async function growPage(', '/* ---------- Bring-back playbooks');
  // A business with no published programme has no version to clone and a recommendation to
  // review, so it still gets the explicit one-sheet.
  assert.match(grow, /if\(!canSetupGrow\|\|!growProgrammeExistsV258\)return openRewardsAutoSetup\(action\);/);
  // And a failed implicit creation falls back to it rather than to a dead button.
  assert.match(grow, /if\(error\|\|!data\?\.version_id\)return openRewardsAutoSetup\(action\);/);
  assert.match(grow, /function openRewardsAutoSetup\(/);
  assert.match(grow, /Review the recommended starting point/);
});

test('C: versioning safety is intact — edits reach a draft, never the live programme', () => {
  const grow = section('async function growPage(', '/* ---------- Bring-back playbooks');
  // The implicit draft is a DRAFT: nothing in the gate publishes.
  const gate = grow.slice(grow.indexOf('const openGrowEditorV258=async(action)=>{'));
  assert.doesNotMatch(gate.slice(0, gate.indexOf('document.querySelectorAll')),
    /publish_loyalty_config|generate_retention_recommendation/);
  // Save still creates a draft before the first server write if one somehow does not exist.
  /* nestly_v415: the old landmark was the draft-only toast, deleted when the owner ruled that
     Save publishes (photo 2). Same handler, closing landmark moved to the publish that replaced
     it. */
  const save = section("const loyaltySave=$('lsave')", "const publishFailedV415=await publishOnSaveV415(versionId);");
  assert.ok(save.indexOf("create_loyalty_config_draft") < save.indexOf("save_loyalty_config_draft"),
    'the draft must exist before any edit reaches the server');
  /* nestly_v415 — REVERSED BY THE OWNER, deliberately. "pressing save would publish to live.
     dont need hide in draft" (photo 2). Customers no longer wait for a separate publish on this
     page. What survives, and is asserted above, is that a draft is still created before the first
     server write — the edit is still versioned, it is simply published immediately after. */
  assert.match(app, /Saved and live for customers/);
  assert.match(app, /savedNotLive/, 'and a publish the server refuses still says so');
});
