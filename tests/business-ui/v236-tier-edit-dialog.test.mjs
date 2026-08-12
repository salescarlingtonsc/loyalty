/* V236 — owner: "when i press edit (basic) tier - it should pop up a box for me to edit it -
   not me scrolling down to find where to edit it." Edit tier opens a dialog at the point of
   action; the single form node is MOVED, never duplicated. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

test('V236 Edit tier opens a dialog named for the tier, not the distant inline form', () => {
  const wire = app.slice(app.indexOf("document.querySelectorAll('.trEdit')"));
  const handler = wire.slice(0, wire.indexOf('});') + 3);
  assert.match(handler, /openTierDialogV236\(tier\?\.name\?`Edit tier — \$\{tier\.name\}`:'Edit tier',b\)/);
  assert.doesNotMatch(handler, /revealTierFormV235/,
    'the edit path must no longer reveal the form at the bottom of the page');
  // + Add tier keeps the inline reveal — the button already sits beside the form.
  assert.match(app, /id="trFormToggleV235"/);
  assert.match(app, /function revealTierFormV235/);
});

test('V236 the dialog reuses the app modal system and moves the ONE form node', () => {
  const open = app.slice(app.indexOf('function openTierDialogV236'), app.indexOf('function closeTierDialogV236'));
  assert.match(open, /class="modal" id="tierDialogV236" role="dialog" aria-modal="true" aria-labelledby="tierDialogTitleV236"/);
  assert.match(open, /class="modal-card"/);
  // The existing form node is appended — its handlers and perk_note plumbing move with it.
  assert.match(open, /querySelector\('#tierDialogSlotV236'\)\.append\(form\)/);
  assert.doesNotMatch(open, /trName"|trTh"/, 'the dialog must not duplicate the form markup');
  // A hidden home marker is planted so close can put the node back exactly where it was.
  assert.match(open, /home\.id='tierDialogHomeV236'/);
  assert.match(open, /form\.before\(home\)/);
});

test('V236 the dialog closes on Close, backdrop and Escape, and restores the form home', () => {
  const open = app.slice(app.indexOf('function openTierDialogV236'), app.indexOf('function closeTierDialogV236'));
  assert.match(open, /if\(e\.target===dialog\)close\(\)/);
  /* V286: Escape, the focus trap and the Android Back entry come from the shared helper. */
  assert.match(open, /CUI\.activateDialog\(dialog,\{onClose:close,initialFocus:'#trName'\}\)/);
  assert.match(open, /opener\?\.focus\?\.\(\)/, 'focus returns to the Edit button that opened it');
  const close = app.slice(app.indexOf('function closeTierDialogV236'), app.indexOf('const trBenefitAddV235'));
  assert.match(close, /home\.after\(form\);form\.hidden=true;/);
  assert.match(close, /toggle\.setAttribute\('aria-expanded','false'\)/);
});

test('V236 a successful save closes the dialog before any re-render can orphan the node', () => {
  const save = app.slice(app.indexOf('async function saveTier('), app.indexOf('const discountBenefitV235'));
  const closeAt = save.indexOf('closeTierDialogV236(false)');
  assert.notEqual(closeAt, -1);
  assert.ok(closeAt < save.indexOf('nav(`#/loyalty/'), 'closes before navigating to the new draft');
  assert.ok(closeAt < save.indexOf('refreshLoyaltyPanel(model,draftVersionId'), 'closes before the panel re-render');
});
