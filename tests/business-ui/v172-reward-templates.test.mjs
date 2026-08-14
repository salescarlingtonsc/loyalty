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
const app = (readFileSync(resolve(repoRoot, 'app/index.html'),'utf8')+'\n'+readFileSync(resolve(repoRoot, 'app/app.js'),'utf8'));

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

/* V303 (owner 2026-08-13: "pressing add rewards - still brings me to this page", screenshotting
   the deep editor's New-reward dialog). A template is an add-reward path, and on a live programme
   it ended in exactly that dialog. The templates themselves are a capability, so they survive
   unchanged — every assertion above still holds — but the chosen one is now handed to the setup
   wizard's INLINE reward form, which is the same three fields and the same writer. */
test('choosing a template reuses the same one add-reward path, no new writers', () => {
  const start = app.indexOf('const templatesOpen=$(');
  assert.ok(start > 0);
  const wiring = app.slice(start, app.indexOf('const growRewardsRetry', start));
  assert.match(wiring, /pendingGrowSetupRewardV303=\{mode:'add',name:template\.name,budgetCents:template\.budget\}/,
    'the template must arm the wizard reward form');
  assert.match(wiring, /nav\('#\/grow\/setup'\)/, 'and land on the wizard, never a dialog');
  assert.doesNotMatch(wiring, /openGrowEditorV258/, 'no template may reach the deep editor dialog');
  assert.doesNotMatch(wiring, /\.insert\(|\.update\(|\.upsert\(/, 'templates must not write server state');
  assert.doesNotMatch(wiring.replace(/from\('services'\)\.select\('price_cents'\)/, ''), /sb\.rpc\(/, 'only the read-only price query is allowed');
});

test('template prefill fills the wizard form and lets the wizard derive points', () => {
  /* V305: the hand-off is gated on the chosen model HAVING a Reward step — a tiers-only
     programme has none, and the old "fall back to the last step" would have dropped the owner on
     the publish gate with a reward form armed. The slice therefore anchors on the declaration name
     rather than on its right-hand side.
     V326: the Points System page's "edit" link added a SECOND mode ('earning') that lands on a
     different step (Earning, not Gifts) and must never arm a reward form — so the single
     up-front `stepNumberOrNullW6I2('reward')===null?null:...` gate this test used to pin moved
     inline, guarding only the reward/edit/add branch; 'earning' has its own 'earn'-step guard
     right above it. Same invariant this test has always asserted (never arm a reward form when
     there is no Reward step to land on), reached a different way now that a second mode exists. */
  const start = app.indexOf('const rewardHandoffV303=');
  assert.ok(start > 0, 'the wizard must consume the hand-off');
  assert.match(app.slice(start, start + 200),
    /const rewardHandoffV303=pendingGrowSetupRewardV303;\s*\r?\n?\s*pendingGrowSetupRewardV303=null;/,
    'the hand-off is consumed once, up front');
  const fn = app.slice(start, start + 1900);
  assert.match(fn, /\}else if\(rewardHandoffV303&&stepNumberOrNullW6I2\('reward'\)!==null\)\{/,
    'and only where there is a Reward step to consume it on');
  assert.match(fn, /pendingGrowSetupRewardV303=null/, 'prefill must be consumed once');
  assert.match(fn, /name:String\(rewardHandoffV303\.name\|\|''\)/);
  assert.match(fn, /Math\.ceil\(budgetCents\/Math\.max\(1,costPerPointCents\(\)\)\)/,
    'the company cost must drive the points price through the one programme-wide rate');
  // The editor-side one-shot is gone with the route it served — an applier with no writer is a
  // silent no-op, and V303 removed both rather than leave one behind.
  assert.doesNotMatch(app, /const applyPendingRewardTemplateV172=/);
});
