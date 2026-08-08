/* V230 — the owner's loyalty-model batch.
   (1) "can just change to Points Redemption / Tiered Membership / stamp card (only 1 can be
       live at any go) - ensure selection by owner will be reflected in the customer portal"
   (2) "stamp - needs to be more flexible ... 3 stamps = xx product, next 5 stamps = xx product
       or discount (% or cash value)"
   (3) "what is this Your rewards - because tiers cannot use points to redeem"
   (4) "tier should not be optional since we are using tiering model" */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const rawApp = readFileSync(join(root, 'app', 'app.js'), 'utf8');
/* The generated zh/ms/ta translation table still carries retired en source strings as lookup
   keys — that is data, not rendered UI. Strip it so doesNotMatch checks judge the render code. */
const app = rawApp.replace(/const WORKSPACE_GENERATED_COPY_V97=Object\.freeze\([\s\S]*?\n\}\);/, ' ');
const migration = readFileSync(join(root, 'db', 'migrations', '20260808_nestly_v230_points_mode_in_customer_portal.sql'), 'utf8');

test('V230 one three-way model select, in the owner\'s words', () => {
  assert.match(app, />Points redemption — earn points, redeem rewards</);
  assert.match(app, />Tiered membership — points build a tier and its benefits</);
  assert.match(app, />Stamp card — collect stamps, milestone rewards</);
  assert.match(app, /Loyalty model — only one is live at a time/);
  // The old three-model taxonomy is gone from the select; simple/catalog became a sub-style.
  assert.doesNotMatch(app, /Simple points — fixed redeem into credit/);
  assert.doesNotMatch(app, /Points \+ reward catalog \+ tiers/);
  /* V235 tied every editor label to its control with for=/id=. */
  assert.match(app, /loyaltySelectionV230==='redeem'\?`<label for="lmStyle">Redemption style<\/label>/);
  // Selection previews on change; Save is the decision point, and it writes BOTH stores.
  assert.match(app, /Loyalty model preview updated — Save to apply\./);
  /* V240: the target gains 'both' — points redemption and tiers may now run together. */
  assert.match(app, /targetModeV230=loyaltySelectionV230==='tiers'\?'tiers':loyaltySelectionV230==='both'\?'both':'redeem'/);
  assert.match(app, /save_loyalty_config_draft[\s\S]{0,800}update\(\{points_mode:targetModeV230\}\)/);
  // A stale preview cannot leak into the next visit.
  assert.match(app, /if\(!stableRefresh\)loyaltyModeDraftV230=null;/);
});

test('V230 the editor shows only the chosen model\'s setup', () => {
  // Tiers model: no "Your rewards" (item 3), tiers headed as the model, not "(optional)" (item 4).
  const start = app.indexOf("?`<b>Tiers — your loyalty model</b>");
  assert.notEqual(start, -1, 'the tiers branch exists at the reward-card call site');
  /* fromIndex matters: the isolation helper is DEFINED earlier in the file, so a plain
     indexOf would land before `start` and slice to an empty string. */
  const site = app.slice(start, app.indexOf('applyGrowLoyaltyEditorIsolationV139', start));
  assert.ok(site.includes('${tierRows()}'), 'tiers branch renders the tier editor');
  /* V240: a 'both' branch now sits between tiers and redeem, so the pure-tiers branch ends at
     that selector rather than at the next `:`<b>`. The invariant is unchanged — a programme
     that only runs tiers still offers nothing to redeem. */
  const tiersOnly = site.slice(0, site.indexOf("loyaltySelectionV230==='both'"));
  assert.notEqual(tiersOnly.length, 0, 'the both branch must follow the tiers branch');
  assert.ok(!tiersOnly.includes('rewardRows'), 'tiers branch must not render the reward list');
  /* V240: tiers are "optional" only in pure redeem — under 'both' they are half the
     programme, so the heading is owned by the redeem case rather than the tiers case. */
  assert.match(app, /\$\{loyaltySelectionV230==='redeem'\?'Tiers \(optional\)':'Your tiers'\}/);
  // The paused warning names the fix instead of just the fact.
  assert.match(app, /the programme Status above is Paused\. Set Status to Active/);
});

test('V230 stamps advertise the milestone ladder the engine already supports', () => {
  assert.match(app, /Stack several milestones below — e\.g\. 3 stamps = free drink, 8 stamps = \$5 credit or a "10% off" benefit\./);
  // Stamps have their own dedicated branch (no tiers rendered there), redeem gets the catalogue.
  assert.match(app, /<b>Milestones<\/b>[\s\S]{0,220}rewardRows\('Your milestones'\)/);
  assert.match(app, /<b>Reward catalogue<\/b><p class="muted small" style="margin-top:6px">Customers spend points on rewards you define\./);
});

test('V230 the customer portal tells one story from the same switch', () => {
  // Server: both wallet readers carry the mode.
  assert.match(migration, /customer_get_effective_tier_v143/);
  assert.match(migration, /customer_get_reward_catalog/);
  assert.match(migration, /''points_mode'',\(select points_mode from public\.businesses where id=p_business\)/);
  // Client: redeem mode hides the tier ladder; tiers mode replaces the rewards list.
  assert.match(app, /if\(String\(tier\.points_mode\|\|''\)==='redeem'\)\{\s*return '';/);
  assert.match(app, /if\(String\(data\?\.points_mode\|\|''\)==='tiers'\)\{/);
  assert.match(app, /Your points build your tier<\/b>/);
});
