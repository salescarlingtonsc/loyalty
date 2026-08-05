import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V172 sector reward templates (owner request 2026-08-06): ready-made rewards per business
   sector, prefilled into the EXISTING reward editor and published through the existing
   draft + Review & publish flow. These assertions pin the design constraints: no new server
   writers, canSetupGrow gating, and the same add-reward path "+ Add reward" uses. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(repoRoot, 'app/index.html'), 'utf8');

test('template row renders only for grow-capable owners', () => {
  const row = app.indexOf('id="growTemplatesOpen"');
  assert.ok(row > 0, 'template row must exist');
  const context = app.slice(row - 220, row);
  assert.match(context, /canSetupGrow\?/, 'row must gate on canSetupGrow');
});

test('every sector resolves a template set with own-price suggestions and fallbacks', () => {
  const start = app.indexOf('const rewardTemplatesForSectorV172');
  assert.ok(start > 0);
  const fn = app.slice(start, app.indexOf('};', app.indexOf('return sets[industry]||sets.other;', start)) + 2);
  for (const sector of ['fnb', 'salon', 'fitness', 'retail', 'other']) {
    assert.match(fn, new RegExp(`${sector}:\\[`), `${sector} templates must exist`);
  }
  assert.match(fn, /sets\.facial=sets\.salon;sets\.massage=sets\.salon;/);
  assert.match(fn, /cheapest\|\|\d+/, 'own-price suggestion must fall back to sector defaults');
  assert.match(fn, /return sets\[industry\]\|\|sets\.other;/, 'unknown sector must fall back, never throw');
});

test('choosing a template reuses the existing add-reward path, no new writers', () => {
  const start = app.indexOf('const templatesOpen=$(');
  assert.ok(start > 0);
  const wiring = app.slice(start, app.indexOf('const growRewardsRetry', start));
  assert.match(wiring, /focusTarget:'rwAdd',activateTarget:true/, 'must open the existing reward editor');
  assert.match(wiring, /if\(!growDraftVersionId\)\{openRewardsAutoSetup\(action\);return\}/, 'cold start must use auto-setup like + Add reward');
  assert.match(wiring, /mountGrowSurface\(action\.surface/, 'draft path must mount the existing surface');
  assert.doesNotMatch(wiring, /\.insert\(|\.update\(|\.upsert\(/, 'templates must not write server state');
  assert.doesNotMatch(wiring.replace(/from\('services'\)\.select\('price_cents'\)/, ''), /sb\.rpc\(/, 'only the read-only price query is allowed');
});

test('template prefill fills the editor fields and lets the editor derive points', () => {
  const start = app.indexOf('const applyPendingRewardTemplateV172');
  assert.ok(start > 0);
  const fn = app.slice(start, start + 1200);
  assert.match(fn, /nameField\.value=template\.name/);
  assert.match(fn, /estimate\.dispatchEvent\(new Event\('input',\{bubbles:true\}\)\)/, 'budget must trigger the existing budget->points maths');
  assert.match(fn, /pendingRewardTemplateV172=null/, 'prefill must be consumed once');
});
