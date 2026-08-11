/* V235 — the owner's loyalty-page batch.
   (1) "how can a spa have table seating at all" — the seating QUESTION is sector-gated.
   (2) "which loyalty model is live right now?" — one Active marker across three model tiles.
   (3) "the add-tier fields are always sitting there" — they hide behind a reveal.
   (4) "Points are used for: Tier membership / Switch to redeeming rewards is confusing" —
       one three-way segmented toggle, with the live model marked.
   Plus the bug behind it all: switching model silently wrote active=false. */
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
const bookings = app.slice(app.indexOf('async function bookingsPage'),
  app.indexOf('\nasync function ', app.indexOf('async function bookingsPage') + 1));

test('(a) the model choice is a three-way segmented toggle that marks what is live', () => {
  for (const key of ['redeem', 'tiers', 'stamps']) {
    assert.match(loyalty, new RegExp(`data-loyalty-model-v235="\\$\\{key\\}"|'${key}'`),
      `${key} must be one of the three segmented options`);
  }
  /* V240: a fourth option, 'both', joins points redemption and tiers (the Chagee model). */
  assert.match(loyalty, /\['redeem','tiers','both','stamps'\]\.map\(key=>`<button type="button" class="loyalty-seg-btn-v235/);
  // Pressed state is programmatic, not colour-only, and the live model carries a text tag.
  assert.match(loyalty, /aria-pressed="\$\{loyaltySelectionV230===key\?'true':'false'\}"/);
  assert.match(loyalty, /liveLoyaltySelectionV235===key\?'<span class="pill on loyalty-seg-live-v235">Live<\/span>':''/);
  // The live model is derived from the SAVED stores, never from the preview override.
  assert.match(loyalty, /const liveLoyaltySelectionV235=\(p\?\.loyalty_model\|\|'classic'\)==='stamps'\?'stamps'/);
  // The buttons drive the existing #lm state, so preview-then-Save semantics are unchanged.
  assert.match(loyalty, /select\.value=button\.dataset\.loyaltyModelV235;\s*\n\s*select\.dispatchEvent\(new Event\('change'\)\);/);
  assert.match(loyalty, /id="lm" class="loyalty-seg-state-v235"/);
  assert.match(shell, /\.loyalty-seg-v235\{display:flex;flex-wrap:wrap/, 'the toggle must wrap, not overflow, at 390px');
});

test('(b) switching model cannot write a different Status than the owner is looking at', () => {
  // Status is module state that survives the preserveFields=false preview re-render...
  assert.match(app, /^let loyaltyStatusDraftV235=null;$/m);
  assert.match(loyalty, /if\(!stableRefresh\)loyaltyStatusDraftV235=null;/);
  assert.match(loyalty, /const loyaltyActiveV235=loyaltyStatusDraftV235===null\?Boolean\(p\?\.active\):loyaltyStatusDraftV235;/);
  // ...the Status control renders from it, so the select can never silently reset...
  assert.match(loyalty, /<option value="true" \$\{loyaltyActiveV235\?'selected':''\}>Active<\/option>/);
  assert.doesNotMatch(loyalty, /<option value="true" \$\{p\?\.active\?'selected':''\}>Active<\/option>/);
  // ...and the model switch captures it before re-rendering. This is the exact fix site.
  const modelSwitch = loyalty.slice(loyalty.indexOf("const loyaltyModelInput=$('lm');"),
    loyalty.indexOf("const loyaltyStyleInput=$('lmStyle');"));
  assert.match(modelSwitch, /const statusInput=\$\('la'\);\s*\n\s*if\(statusInput\)loyaltyStatusDraftV235=statusInput\.value==='true';/);
  assert.ok(modelSwitch.indexOf('loyaltyStatusDraftV235=statusInput.value') < modelSwitch.indexOf('refreshLoyaltyPanel'),
    'the Status must be captured BEFORE the preview re-render throws the fields away');
  // Saving is what clears it — the draft never outlives the value it protected.
  assert.match(loyalty, /if\(saveError\)\{\$\('lsave'\)\.disabled=false;return fail\(saveError\)\}\s*\n\s*loyaltyStatusDraftV235=null;/);
  // Touching Status directly records it too, so a plain edit is preserved the same way.
  assert.match(loyalty, /loyaltyStatusInputV235\.onchange=\(\)=>\{\s*\n\s*loyaltyStatusDraftV235=loyaltyStatusInputV235\.value==='true';/);
});

test('(c) the add-tier fields are hidden behind a reveal button', () => {
  assert.match(loyalty, /<button class="btn ghost sm" id="trFormToggleV235" type="button" aria-expanded="false" aria-controls="trFormV235"[^>]*>\+ Add tier<\/button>/);
  assert.match(loyalty, /<div class="tier-editor" id="trFormV235" hidden/);
  assert.match(loyalty, /function revealTierFormV235\(focusFirst\)\{[\s\S]{0,260}?host\.hidden=false;/);
  assert.match(loyalty, /if\(focusFirst\)\$\('trName'\)\?\.focus\(\{preventScroll:true\}\)/);
  assert.match(loyalty, /trFormToggleV235\.onclick=\(\)=>\{fillTier\(null\);revealTierFormV235\(true\)\}/);
  // Editing an existing tier opens the same form rather than leaving it hidden.
  /* V236: Edit tier now opens a dialog at the card instead of revealing the form at the
     bottom of the page — see tests/business-ui/v236-tier-edit-dialog.test.mjs. */
  assert.match(loyalty, /openTierDialogV236\(tier\?\.name\?`Edit tier — \$\{tier\.name\}`:'Edit tier',b\)/);
});

test('(d) the table-seating question is sector-gated, and booking rules survive', () => {
  /* V276 retarget: 'bar' joined the seated sectors — the copy under the switch already named a
     bar, but the list did not, so the one sector it names by hand never saw the control. The
     gating shape this test exists to pin is unchanged. */
  assert.match(bookings, /const seatingSectorV235=\['fnb','bar','other'\]\.includes\(String\(S\.biz\.industry\|\|''\)\.toLowerCase\(\)\);/);
  assert.match(bookings, /const seatsGuestsV235=seatingSectorV235&&S\.biz\.takes_table_reservations===true;/);
  // The toggle itself only renders for a seated sector...
  assert.match(bookings, /\$\{seatingSectorV235\?`<label[^`]*id="setTakesTablesV223"/s);
  // ...and so does everything downstream of it.
  assert.match(bookings, /\$\{seatsGuestsV235\?`<div class="row"><b>Tables \/ capacity<\/b>/);
  assert.match(bookings, /\$\{seatsGuestsV235\?`<label>When you're full<\/label>/);
  // Booking rules are NOT inside the gate — every sector still sets its hold timer.
  const rules = bookings.slice(bookings.indexOf('Booking rules'), bookings.indexOf('id="setSave"'));
  assert.ok(!rules.includes('${seatingSectorV235?'), 'the booking-rules block must render for every sector');
  assert.match(bookings, /const takesTables=\$\('setTakesTablesV223'\)\?\$\('setTakesTablesV223'\)\.checked:null;/,
    'a hidden toggle must send null, leaving the stored value alone');
});

test('(e) two "% off" benefit lines are flagged, never merged or deleted', () => {
  assert.match(loyalty, /const tierDuplicateDiscountV235=\(tier\)=>tierBenefitLines\(tier\)\.filter\(line=>\/\^\\d\+% off\/\.test\(line\)\)\.length>1;/);
  assert.match(loyalty, /\$\{tierDuplicateDiscountV235\(t\)\?'<p class="loyalty-flag-v235"[^>]*>Two discounts are listed — customers see both\. Keep the one you mean\.<\/p>':''\}/);
  assert.match(shell, /\.loyalty-flag-v235\{[^}]*color:var\(--amber\)/);
  // Nothing in the render path removes a benefit line; the flag is advisory only.
  assert.doesNotMatch(loyalty, /tierBenefitLines\(t\)\.filter\([^)]*\)\.slice\(0,1\)/);
  // The checklist stops a SECOND discount being added, which is where the pair came from.
  assert.match(loyalty, /const discountBenefitV235=\(text\)=>\/\^\\d\+% off\/\.test\(String\(text\|\|''\)\);/);
  assert.match(loyalty, /if\(discountBenefitV235\(benefit\)\)document\.querySelectorAll\('\[data-tier-benefit\]'\)\.forEach\(other=>\{/);
  // perk_note stays one newline-joined field — structured rows are an input method only.
  assert.match(loyalty, /textarea\.value=\[\.\.\.host\.querySelectorAll\('\[data-tier-benefit-row-v235\]'\)\]\s*\n\s*\.map\(input=>input\.value\.trim\(\)\)\.filter\(Boolean\)\.join\('\\n'\);/);
});

test('(f) the birthday reward is a collapsed optional card until it is configured', () => {
  assert.match(loyalty, /<details class="loyalty-optional-v235" \$\{publishedBirthdayProgram\?'open':''\}>/);
  assert.match(loyalty, /<details class="loyalty-optional-v235" \$\{birthdayProgram\?'open':''\}>/);
  assert.match(loyalty, /<summary><b>Birthday reward<\/b><span class="muted small">give customers a reason to visit in their birthday month\.<\/span>/);
  assert.match(loyalty, /id="birthdayStartDraft"[^>]*>\$\{publishedBirthdayProgram\?'Edit':'Set up'\}/);
  // Its own save handler is genuinely separate, so it stays — as a small inline action.
  assert.match(loyalty, /<button class="btn ghost sm" id="birthdaySaveDraft">Save birthday reward<\/button>/);
  assert.match(loyalty, /save_birthday_program_draft/);
});

test('one status strip, one primary action pair, no version-speak', () => {
  // Exactly one strip renders: paused wins over draft, and each carries one action.
  assert.match(loyalty, /const loyaltyStripV235=\(\(\)=>\{/);
  assert.match(loyalty, /if\(p&&!loyaltyActiveV235\)return `<div class="loyalty-strip-v235" id="loyaltyStripV235"/);
  assert.match(loyalty, /if\(draftVersionId\)return `<div class="loyalty-strip-v235" id="growDraftBarV170"/);
  assert.equal((loyalty.match(/\$\{loyaltyStripV235\}/g) || []).length, 1);
  assert.doesNotMatch(loyalty, /You have unpublished changes — customers still see the old programme\./);
  // Paused is an intentional state with a resume that sets the control and does NOT auto-save.
  assert.match(loyalty, /Paused<\/b> — customers are not earning right now\./);
  assert.match(loyalty, /status\.value='true';loyaltyStatusDraftV235=true;/);
  assert.ok(!loyalty.slice(loyalty.indexOf("loyaltyResumeV235.onclick"), loyalty.indexOf("const loyaltySaveStateV235="))
    .includes('sb.rpc'), 'Resume must not write anything on its own');
  // One primary pair, at the top of the editor, with a plain status line.
  assert.match(loyalty, /<div class="loyalty-actions-v235">\s*\n\s*<button class="btn" id="lsave">Save changes<\/button>\s*\n\s*<button class="btn ghost" id="loyaltyReviewPublish"/);
  // Header carries the tagline and a dot+text status pill.
  assert.match(loyalty, /subtitle:'Build a programme that keeps customers coming back\.'/);
  assert.match(loyalty, /<span class="pill \$\{loyaltyStatusV235\.tone\}" id="loyaltyStatusPillV235"><span aria-hidden="true">●<\/span> \$\{esc\(loyaltyStatusV235\.label\)\}/);
  // Version-speak is gone from what the owner reads on this page.
  assert.doesNotMatch(loyalty, /configuration version/i);
  assert.doesNotMatch(loyalty, /versioned changes/i);
  assert.match(loyalty, /Customers will see your latest published programme\./);
  // Expiry and branch settings are collapsed advanced settings.
  assert.match(loyalty, /<details class="loyalty-advanced-v235" id="loyaltyAdvancedV235"[^>]*><summary>Advanced settings<\/summary>/);
});

test('the programme overview and customer preview speak plain language', () => {
  assert.match(loyalty, /const loyaltyModelCopyV235=\{/);
  assert.match(loyalty, /Customers earn points on every visit and unlock better benefits as they move up\./);
  assert.match(loyalty, /const loyaltyFactsV235=loyaltySelectionV230==='tiers'/);
  assert.match(loyalty, /\['How customers earn',loyaltyEarnFactV235\],\['Tier level from',tierBasisFactV235\],\['Tiers',`\$\{tiers\.length\}`\]/);
  // Tier cards: requirement in words, benefits as bullets, the lifetime note said once above.
  assert.match(loyalty, /if\(!threshold\)return 'Starting tier';/);
  assert.match(loyalty, /return `Unlock at \$\{threshold\.toLocaleString\('en-SG'\)\} \$\{tierBasisWordV235\}`;/);
  assert.match(loyalty, /Tiers are based on lifetime \$\{esc\(tierBasisWordV235\)\} — spending points never drops anyone down\./);
  assert.doesNotMatch(app, /lifetime, so redeeming never drops a tier/);
  assert.match(loyalty, /<b>How customers move up\.<\/b> Earn \$\{p\?\.earn_points_per_dollar\?\?1\} points per \$1\./);
  assert.match(loyalty, /const customerPreviewV235=loyaltySelectionV230==='tiers'/);
  assert.match(loyalty, /<b>What your customers see<\/b>/);
});
