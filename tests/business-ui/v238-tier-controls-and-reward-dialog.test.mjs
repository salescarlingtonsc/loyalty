/* V238 — the owner's loyalty-editor batch.
   (1) "when change from 1.5 to 1.2 it does not reflect" — a Diamond tier read "50% more points
       on every spend" beside a 1.25x multiplier, because the recommended-tiers helper wrote the
       sentence once and nothing revisited it. The multiplier now OWNS that line.
   (2) "instead of multiple % to choose from, give me a drag and pull bar ... able to type the %
       as well" — the two fixed "% off" presets become one slider + typed percentage that owns
       exactly one discount line, so a second discount cannot be created from the form at all.
   (3) "there should not be points redemption for tiered membership - why can use points for
       free moisturizer?" — no point-priced reward chips in tiers mode; legacy lines are flagged,
       never rewritten.
   (4) "i cannot edit the reward" — #rwEditor sits below the whole reward list, so Edit rendered
       a form off screen. Same fix as V236: the ONE editor node moves into a dialog. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const rawApp = readFileSync(join(root, 'app', 'app.js'), 'utf8');
/* The generated zh/ms/ta table carries retired en source strings as lookup keys — data, not
   rendered UI. Strip it so doesNotMatch checks judge the render code. */
const app = rawApp.replace(/const WORKSPACE_GENERATED_COPY_V97=Object\.freeze\([\s\S]*?\n\}\);/, ' ');
const shell = readFileSync(join(root, 'app', 'index.html'), 'utf8');
const loyalty = app.slice(app.indexOf('async function loyaltyPage('), app.indexOf('async function retentionPage('));

/* The derived-line helpers are pure and module-scope, so they are executed rather than
   pattern-matched — the rounding is the thing the owner actually saw go wrong. */
const helpers = new Function(`${app.slice(
  app.indexOf('const BONUS_POINTS_LINE_RE_V238'),
  app.indexOf('/* The threshold means different things per firm'),
)}
return {BONUS_POINTS_LINE_RE_V238,DISCOUNT_LINE_RE_V238,bonusPointsLineV238,discountLineV238};`)();

test('(a) the bonus-points benefit line is derived from the multiplier, and disappears at 1x', () => {
  const { bonusPointsLineV238, BONUS_POINTS_LINE_RE_V238 } = helpers;
  assert.equal(bonusPointsLineV238(1.5), '50% more points on every spend');
  assert.equal(bonusPointsLineV238(1.25), '25% more points on every spend');
  assert.equal(bonusPointsLineV238(1.2), '20% more points on every spend', 'the owner\'s 1.5 -> 1.2 edit');
  assert.equal(bonusPointsLineV238(1), '', 'no bonus at 1x means no sentence at all');
  assert.equal(bonusPointsLineV238(0.5), '');
  assert.equal(bonusPointsLineV238(''), '');
  assert.equal(bonusPointsLineV238('abc'), '');
  // Whatever the helper writes must be what the reconciler later recognises and replaces.
  assert.ok(BONUS_POINTS_LINE_RE_V238.test(bonusPointsLineV238(1.5)));
  assert.ok(BONUS_POINTS_LINE_RE_V238.test('50% more points on every spend'));
  assert.ok(!BONUS_POINTS_LINE_RE_V238.test('Birthday treat every year'));

  // One line, replaced in place — perk_note stays the same newline-joined field.
  const replace = app.slice(app.indexOf('function tierPerkReplaceLineV238'), app.indexOf('function syncTierBonusPointsLineV238'));
  assert.match(replace, /const at=lines\.findIndex\(value=>pattern\.test\(value\)\);/);
  assert.match(replace, /if\(line\)\{if\(at>=0\)lines\[at\]=line;else lines\.push\(line\)\}/);
  assert.match(replace, /else if\(at>=0\)lines\.splice\(at,1\);/);
  assert.match(replace, /textarea\.value=next/, 'the source of truth is still #trPerk');
  assert.match(loyalty, /function syncTierBonusPointsLineV238\(\)\{\s*\n\s*return tierPerkReplaceLineV238\(BONUS_POINTS_LINE_RE_V238,bonusPointsLineV238\(\$\('trMul'\)\?\.value\)\);/);

  // Typing in the multiplier rewrites the line, then re-renders the rows over it.
  const wire = loyalty.slice(loyalty.indexOf("const trMulFieldV238=$('trMul');"));
  const block = wire.slice(0, wire.indexOf("['trDiscountRangeV238'"));
  assert.match(block, /syncTierBonusPointsLineV238\(\);\s*\n\s*tierBenefitRowsRenderV235\(\);syncTierBenefitPicksV182\(\);markTierDirtyV237\(\);/);
  assert.match(block, /addEventListener\('input',applyMultiplierV238\)/);
  assert.match(block, /addEventListener\('change',applyMultiplierV238\)/);
});

test('(a2) opening a tier corrects a stale line without reporting unsaved work', () => {
  const fill = loyalty.slice(loyalty.indexOf('const fillTier=(tier)=>'), loyalty.indexOf('function syncTierBenefitPicksV182'));
  const reconcile = fill.indexOf('syncTierBonusPointsLineV238();');
  assert.notEqual(reconcile, -1);
  assert.ok(reconcile > fill.indexOf("$('trPerk').value=tierBenefitLines(tier)"), 'reconcile after perk_note is loaded');
  assert.ok(reconcile > fill.indexOf("$('trMul').value="), 'reconcile after the multiplier is loaded');
  assert.ok(reconcile < fill.indexOf('resetTierBaselineV237()'),
    'the corrected line must be part of the baseline, or merely opening a tier reads as dirty');
  assert.ok(fill.indexOf('syncTierDiscountControlsFromPerkV238();') < fill.indexOf('resetTierBaselineV237()'));
});

test('(b) the fixed "% off" presets are gone, replaced by one slider + typed percentage', () => {
  // The two preset lines an owner could stack are no longer offerable.
  const presets = app.slice(app.indexOf('const TIER_BENEFIT_PRESETS_V182'), app.indexOf('/* V238: two tier benefit lines'));
  assert.doesNotMatch(presets, /5% off every visit/);
  assert.doesNotMatch(presets, /10% off every visit/);
  // The benefits that were never a percentage survive untouched.
  assert.match(presets, /Birthday treat every year/);
  assert.match(presets, /Priority booking/);
  assert.match(presets, /First access to new services/);
  assert.match(presets, /Free add-on with every visit/);
  assert.match(presets, /A welcome gift when they reach this tier/);

  assert.match(loyalty, /<input type="range" id="trDiscountRangeV238" min="0" max="100" step="1" value="0"/);
  assert.match(loyalty, /<input type="number" id="trDiscountPctV238" min="0" max="100" step="1" value="0"/);
  assert.match(loyalty, /<span aria-hidden="true">%<\/span>/);

  const { discountLineV238 } = helpers;
  assert.equal(discountLineV238(15), '15% off every visit');
  assert.equal(discountLineV238(0), '', 'zero means no discount line at all');
  assert.equal(discountLineV238(''), '');

  // Both inputs are two views of one value, clamped 0..100, non-numeric -> 0.
  const clamp = loyalty.slice(loyalty.indexOf('function setTierDiscountControlsV238'), loyalty.indexOf('function syncTierDiscountControlsFromPerkV238'));
  assert.match(clamp, /Number\.isFinite\(rounded\)\?Math\.min\(100,Math\.max\(0,rounded\)\):0/);
  assert.match(clamp, /if\(range\)range\.value=String\(clamped\);/);
  assert.match(clamp, /if\(number\)number\.value=String\(clamped\);/);

  // The pair owns exactly ONE line, so a second discount cannot be created from this form.
  const apply = loyalty.slice(loyalty.indexOf('function applyTierDiscountV238'), loyalty.indexOf('/* A derived row is shown'));
  assert.match(apply, /tierPerkReplaceLineV238\(DISCOUNT_LINE_RE_V238,discountLineV238\(pct\)\);/);
  assert.match(apply, /tierBenefitRowsRenderV235\(\);syncTierBenefitPicksV182\(\);markTierDirtyV237\(\);/);
  assert.match(loyalty, /\['trDiscountRangeV238','trDiscountPctV238'\]\.forEach\(id=>\{/);

  // V235's amber flag on the tier CARD stays: legacy data can still carry two lines.
  assert.match(loyalty, /const tierDuplicateDiscountV235=\(tier\)=>tierBenefitLines\(tier\)\.filter\(line=>\/\^\\d\+% off\/\.test\(line\)\)\.length>1;/);
  assert.match(loyalty, /Two discounts are listed — customers see both\. Keep the one you mean\./);

  assert.match(shell, /\.tier-discount-row-v238\{[^}]*min-height:44px/, 'a 44px touch target row');
  assert.match(shell, /\.tier-discount-row-v238 input\[type=range\]:focus-visible\{[^}]*outline:2px solid var\(--coral\)/);
  assert.match(shell, /@media\(max-width:390px\)\{\s*\n\s*\.tier-discount-row-v238 input\[type=range\]\{flex:1 1 100%\}/);
});

test('(c) a tiered programme offers no point-priced rewards, and flags the legacy ones', () => {
  // The chip row is not rendered at all in tiers mode — no empty row, no stray label.
  assert.match(loyalty, /\$\{tierRewardChipsAllowedV240&&rewards\.filter\(reward=>reward\.active!==false\)\.length\?`<div class="row"[^`]*<span class="muted small">Or add one of your rewards:<\/span>/);
  // Defence in depth: the handler refuses even if a chip somehow exists.
  const handler = loyalty.slice(loyalty.indexOf("document.querySelectorAll('.trBenefitReward')"));
  assert.match(handler.slice(0, handler.indexOf('});') + 3), /if\(!tierRewardChipsAllowedV240\)return;/);

  // A legacy "(N points)" line is flagged where it is read. Never rewritten, never deleted.
  assert.match(loyalty, /const tierPointPricedBenefitV238=\(line\)=>loyaltySelectionV230==='tiers'&&\/\\\(\\d\+ points\\\)\$\/i\.test\(String\(line\|\|''\)\);/);
  assert.match(loyalty, /\$\{tierPointPricedBenefitV238\(benefit\)\?'<p class="loyalty-flag-v235"[^>]*>This benefit still charges points, which a tiered programme never spends\. Edit the tier to reword it\.<\/p>':''\}/);
  assert.doesNotMatch(loyalty, /tierPointPricedBenefitV238\([^)]*\)\)?\s*\{\s*lines\.splice/, 'the owner\'s line is never auto-removed');
});

test('(d) Edit reward opens a dialog that MOVES the one editor node', () => {
  const open = loyalty.slice(loyalty.indexOf('function openRewardDialogV238'), loyalty.indexOf('function closeRewardDialogV238'));
  assert.match(open, /class="modal" id="rewardDialogV238" role="dialog" aria-modal="true" aria-labelledby="rewardDialogTitleV238"/);
  assert.match(open, /class="modal-card"/);
  assert.match(open, /<h2 id="rewardDialogTitleV238"/);
  assert.match(open, /querySelector\('#rewardDialogSlotV238'\)\.append\(editor\)/);
  assert.doesNotMatch(open, /rwCustomerName"|rwSave"/, 'the dialog must not duplicate the reward form markup');
  assert.match(open, /home\.id='rewardDialogHomeV238'/);
  assert.match(open, /editor\.before\(home\)/);

  // Three close paths, all returning focus to whatever opened the dialog.
  assert.match(open, /if\(e\.target===dialog\)close\(\)/, 'backdrop');
  /* V286: Escape (and the focus trap, and Android Back) now come from the shared helper
     instead of a hand-rolled dialog.onkeydown. */
  assert.match(open, /CUI\.activateDialog\(dialog,\{onClose:close,initialFocus:'#rwCustomerName'\}\)/, 'Escape');
  assert.match(open, /const done=\$\('rwClose'\);if\(done\)done\.onclick=close;/, 'the editor\'s own Done button');
  assert.match(open, /const close=\(\)=>\{closeRewardDialogV238\(true\);opener\?\.focus\?\.\(\)\}/);

  // openRewardEditor re-renders #rwEditor.innerHTML, so #rwClose is bound AFTER that render.
  const editorFn = loyalty.slice(loyalty.indexOf('function openRewardEditor(reward)'), loyalty.indexOf('/* V238 (owner: "i cannot edit the reward")'));
  assert.match(editorFn, /\$\('rwClose'\)\.onclick=\(\)=>document\.getElementById\('rewardDialogV238'\)\?closeRewardDialogV238\(true\):finishGrowEditorV139\(\);/,
    'Done still leaves the editor when no dialog is open');

  const close = loyalty.slice(loyalty.indexOf('function closeRewardDialogV238'), loyalty.indexOf('async function saveReward('));
  assert.match(close, /if\(editor&&home&&restore\)\{home\.after\(editor\);editor\.innerHTML=''\}/);

  // Both openers render first, then move the node into the dialog.
  assert.match(loyalty, /if\(ra\) ra\.onclick=\(\)=>\{openRewardEditor\(null\);openRewardDialogV238\('New reward',ra\)\};/);
  const edit = loyalty.slice(loyalty.indexOf("document.querySelectorAll('.rwEdit')"));
  const editHandler = edit.slice(0, edit.indexOf('});') + 3);
  assert.match(editHandler, /openRewardEditor\(reward\);/);
  assert.match(editHandler, /openRewardDialogV238\(reward\?`Edit reward — \$\{rewardLabel\(reward\)\}`:'Edit reward',b\)/);
});

test('(d2) a successful reward save closes the dialog before any re-render can orphan the node', () => {
  const save = loyalty.slice(loyalty.indexOf('async function saveReward('), loyalty.indexOf("const ra=$('rwAdd');"));
  const closeAt = save.indexOf('closeRewardDialogV238(false)');
  assert.notEqual(closeAt, -1);
  assert.ok(closeAt < save.indexOf('openProtectedGrowPublishReview(versionId)'), 'closes before the publish-review navigation');
  /* V293: the save's exit is now spendRewardIntentV293() — same guarantee this test always
     held (dialog closed BEFORE any navigation can orphan the moved editor node). */
  assert.ok(closeAt < save.indexOf('spendRewardIntentV293()'), 'closes before leaving the editor');
});

test('(e) derived benefit rows are read-only, and Remove resets the control that owns them', () => {
  const hint = loyalty.slice(loyalty.indexOf('function tierDerivedBenefitHintV238'), loyalty.indexOf('function tierBenefitRowMarkupV235'));
  assert.match(hint, /if\(BONUS_POINTS_LINE_RE_V238\.test\(line\)\)return 'Set by Points earning speed above';/);
  assert.match(hint, /if\(DISCOUNT_LINE_RE_V238\.test\(line\)\)return 'Set by the discount slider above';/);

  const markup = loyalty.slice(loyalty.indexOf('function tierBenefitRowMarkupV235'), loyalty.indexOf('function tierBenefitRowsCommitV235'));
  assert.match(markup, /const derived=tierDerivedBenefitHintV238\(value\);/);
  /* The hint is a visible paragraph + aria-describedby rather than title=: an interpolated
     title is an unclassified dynamic accessibility attribute under the v97 workspace audit. */
  assert.match(markup, /\$\{derived\?` readonly aria-describedby="trBenefitHint\$\{index\}V238"`:''\}/);
  assert.match(markup, /\$\{derived\?`<p class="muted small tier-benefit-derived-v238" id="trBenefitHint\$\{index\}V238">\$\{esc\(derived\)\}<\/p>`:''\}/);
  // A hand-written benefit is still freely editable.
  assert.ok(!/ readonly[^$]/.test(markup.replace(/\$\{derived\?[\s\S]*?:''\}/g, '')), 'only derived rows are read-only');

  const bind = loyalty.slice(loyalty.indexOf('function tierBenefitRowBindV235'), loyalty.indexOf('function tierBenefitRowsRenderV235'));
  assert.match(bind, /if\(BONUS_POINTS_LINE_RE_V238\.test\(value\)&&\$\('trMul'\)\)\$\('trMul'\)\.value='1';/);
  assert.match(bind, /if\(DISCOUNT_LINE_RE_V238\.test\(value\)\)setTierDiscountControlsV238\(0\);/);
  assert.match(bind, /row\.remove\(\);tierBenefitRowsCommitV235\(\)\};/, 'Remove still removes the row');
  assert.match(shell, /\.tier-benefit-row-v235 input\[readonly\]\{/);
});
