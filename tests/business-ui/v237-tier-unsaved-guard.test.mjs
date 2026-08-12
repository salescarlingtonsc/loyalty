/* V237 — owner: "why is this static? i already remove 50% benefit - but it still shows the 50%
   here, not accurate."
   Ground truth in production said the removal was never stored: Remove only rewrites the form's
   perk_note field, and the tier is written when Save tier is pressed. Closing the dialog threw
   that away in silence, so reopening showed the old benefit. The form now says when it holds
   unsaved work and will not close quietly on it. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const shell = readFileSync(join(root, 'app', 'index.html'), 'utf8');

test('V237 removing a benefit marks the tier form unsaved', () => {
  const commit = app.slice(app.indexOf('function tierBenefitRowsCommitV235'), app.indexOf('function tierFormSignatureV237'));
  assert.match(commit, /markTierDirtyV237\(\);/,
    'the row commit that Remove and row edits both run must flag unsaved work');
  // Every other way of changing the tier flags it too.
  assert.match(app, /\['trName','trTh','trMul','trFrom','trUntil'\]\.forEach\(id=>\{[\s\S]{0,140}addEventListener\('input',markTierDirtyV237\)/);
  assert.match(app, /tierBenefitRowsRenderV235\(\);markTierDirtyV237\(\);\s*\n\s*\}\);/, 'preset tick boxes');
  assert.match(app, /syncTierBenefitPicksV182\(\);tierBenefitRowsRenderV235\(\);markTierDirtyV237\(\);revealTierFormV235\(false\)/, 'reward chips');
});

test('V237 the dirty flag is measured against the tier as stored, not a bare boolean', () => {
  const sig = app.slice(app.indexOf('function tierFormSignatureV237'), app.indexOf('function markTierDirtyV237'));
  // Name, threshold, multiplier, benefits and both schedule bounds all count.
  for (const field of ['trName', 'trTh', 'trMul', 'trPerk', 'trFrom', 'trUntil']) {
    assert.match(sig, new RegExp(`\\$\\('${field}'\\)`), `${field} must be part of the signature`);
  }
  const mark = app.slice(app.indexOf('function markTierDirtyV237'), app.indexOf('function setTierDirtyStateV237'));
  assert.match(mark, /tierFormSignatureV237\(\)!==tierBaselineV237/,
    'editing a field back to its stored value must clear the flag again');
  // Opening a tier re-baselines, so a freshly opened tier is never falsely dirty.
  const fill = app.slice(app.indexOf('const fillTier=(tier)=>'), app.indexOf('function syncTierBenefitPicksV182'));
  assert.match(fill, /resetTierBaselineV237\(\)\}/);
});

test('V237 closing the dialog with unsaved work asks first', () => {
  const open = app.slice(app.indexOf('function openTierDialogV236'), app.indexOf('function closeTierDialogV236'));
  assert.match(open, /if\(tierDirtyV237&&!confirm\('Discard your unsaved changes to this tier\?'\)\)return;/);
  // One close path feeds the Close button, the backdrop, Escape and Android Back, so all are
  // guarded — V286 moved the last two into CUI.activateDialog's onClose, which is that same path.
  assert.match(open, /querySelector\('#tierDialogCloseV236'\)\.onclick=close/);
  assert.match(open, /if\(e\.target===dialog\)close\(\)/);
  assert.match(open, /CUI\.activateDialog\(dialog,\{onClose:close,/);
  // The state is announced, and survives the dialog node being rebuilt.
  assert.match(open, /setTierDirtyStateV237\(tierDirtyV237\)/);
  assert.match(app, /id="tierDialogDirtyV237" role="status" aria-live="polite"/);
  assert.match(app, /Unsaved changes — press Save tier to keep them\./);
  assert.match(shell, /\.tier-dialog-dirty-v237\{/);
});

test('V237 a stored save clears the flag before the dialog closes', () => {
  const save = app.slice(app.indexOf('async function saveTier('), app.indexOf('const discountBenefitV235'));
  const cleared = save.indexOf('setTierDirtyStateV237(false)');
  assert.notEqual(cleared, -1, 'a successful save is not unsaved work');
  assert.ok(cleared < save.indexOf('closeTierDialogV236(false)'),
    'clearing must precede the close, or saving would prompt to discard');
});

test('V237 two rewards sharing a customer name are told apart in the picker', () => {
  const picker = app.slice(app.indexOf('Or add one of your rewards:'), app.indexOf('id="trBenefitRowsV235"'));
  assert.match(picker, /seen\[label\]>1&&reward\.internal_name\?`\$\{label\} \(\$\{reward\.internal_name\}\)`:label/);
  // The line written into perk_note stays the customer-facing name, so storage is unchanged.
  assert.match(picker, /data-benefit="\$\{esc\(`\$\{label\} \(\$\{reward\.cost_points\} \$\{unit\}\)`\)\}"/);
});
