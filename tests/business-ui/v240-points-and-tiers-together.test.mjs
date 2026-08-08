/* V240 — owner, with Chagee as the reference: "we can allow 2 ongoing rewards (points & tier);
   tier is by number of visits while points is for redemption."
   V229 made points-vs-tiers exclusive because points doing double duty is incoherent: if the
   same points both buy rewards and decide the tier, spending them should cost the customer
   their status. Chagee avoids that by earning the tier from CUPS (visits) and keeping points a
   separate spendable currency. So the real invariant was never "one or the other" — it is
   "points may not MEASURE the tier while they are also spendable", which the server now
   enforces with a trigger (sqlstate 23514). These tests pin the client to that rule. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const migration = readFileSync(join(root, 'db', 'migrations', '20260808_nestly_v239_points_and_tiers_can_both_run.sql'), 'utf8');

test('V240 the server allows both and refuses only the incoherent pairing', () => {
  assert.match(migration, /check \(points_mode is null or points_mode = any \(array\['redeem','tiers','both'\]\)\)/);
  assert.match(migration, /if v_mode = 'both' and v_basis = 'points_earned' then/);
  assert.match(migration, /set the tier to visits or spend/);
  // Both write paths are guarded, because either side can create the state.
  assert.match(migration, /create trigger v239_guard_points_mode\s+before update of points_mode on public\.businesses/);
  assert.match(migration, /create trigger v239_guard_tier_basis\s+before insert or update of tier_basis on public\.loyalty_programs/);
  // The redemption gate is deliberately untouched: it refuses 'tiers' only, so 'both' redeems.
  assert.doesNotMatch(migration, /create or replace function public\.customer_create_redemption_intent_v89/);
});

test('V240 the editor offers a fourth model and derives the selection from it', () => {
  assert.match(app, /const loyaltySelectionForModeV240=mode=>mode==='tiers'\?'tiers':mode==='both'\?'both':'redeem';/);
  assert.match(app, /loyaltySelectionV230=model==='stamps'\?'stamps':loyaltySelectionForModeV240\(loyaltyModeV230\)/);
  assert.match(app, /liveLoyaltySelectionV235=\(p\?\.loyalty_model\|\|'classic'\)==='stamps'\?'stamps'\s*\n\s*:loyaltySelectionForModeV240/);
  assert.match(app, /both:\{name:'Points \+ tiers',line:'Customers spend points on rewards, and separately climb tiers by visits/);
  assert.match(app, /\$\{\['redeem','tiers','both','stamps'\]\.map\(key=>/);
  // The group label no longer claims exclusivity, because it is no longer true.
  assert.doesNotMatch(app, /aria-label="Loyalty model — only one is live at a time"/);
});

test('V240 both renders the catalogue AND the ladder', () => {
  const site = app.slice(app.indexOf("?`<b>Tiers — your loyalty model</b>"), app.indexOf('applyGrowLoyaltyEditorIsolationV139', app.indexOf("?`<b>Tiers — your loyalty model</b>")));
  const both = site.slice(site.indexOf("loyaltySelectionV230==='both'"));
  assert.match(both, /rewardRows\('Your rewards'\)\}\$\{tierRows\(\)\}/,
    'both must reuse the same composables, not fork them');
  assert.match(both, /Both run together: points buy rewards, visits build tiers\./);
  // Pure tiers still hides rewards; pure redeem still hides tiers.
  assert.match(site, /Point rewards are off in this model/);
  assert.match(site, /Tiers are off in this model/);
});

test('V240 the tier basis can never offer points while points are spendable', () => {
  assert.match(app, /const tierBasisAllowsPointsV240=loyaltySelectionV230!=='both';/);
  // A stored points ladder reads as visits the moment 'both' is previewed, so what the owner
  // sees is what Save can actually write.
  assert.match(app, /return !tierBasisAllowsPointsV240&&stored==='points_earned'\?'visits':stored/);
  assert.match(app, /\$\{tierBasisAllowsPointsV240\?`<option value="points_earned"/);
  assert.match(app, /Tiers count visits so points stay free to spend\./);
});

test('V240 the save path writes a safe basis first and explains a refusal', () => {
  const save = app.slice(app.indexOf("const loyaltySave=$('lsave')"), app.indexOf("if(draftVersionId){\n      toast('Grow draft saved"));
  assert.match(save, /targetModeV230=loyaltySelectionV230==='tiers'\?'tiers':loyaltySelectionV230==='both'\?'both':'redeem'/);
  // The basis leaves for the server already free of points when heading into 'both'.
  assert.match(save, /row\.tier_basis=targetModeV230==='both'&&basisV240==='points_earned'\?'visits':basisV240/);
  // The draft save (carrying tier_basis) precedes the points_mode switch — the order the
  // database trigger requires.
  assert.ok(save.indexOf("save_loyalty_config_draft") < save.indexOf("update({points_mode:targetModeV230})"));
  // A refusal states the fix and does NOT discard the owner's choice.
  assert.match(save, /modeError\.code==='23514'\|\|\/measure its tiers in points\/i\.test\(modeError\.message\|\|''\)/);
  const refusal = save.slice(save.indexOf("modeError.code==='23514'"));
  assert.ok(refusal.indexOf('loyaltyModeDraftV230=null') === -1 || refusal.indexOf('return toast(') < refusal.indexOf('loyaltyModeDraftV230=null'),
    'the mode draft must survive a refusal so the choice is not silently lost');
});

test('V240 reward chips return in both, and stay hidden in pure tiers', () => {
  assert.match(app, /const tierRewardChipsAllowedV240=loyaltySelectionV230!=='tiers';/);
  assert.match(app, /\$\{tierRewardChipsAllowedV240&&rewards\.filter/);
  assert.match(app, /if\(!tierRewardChipsAllowedV240\)return;/);
  // The legacy "(N points)" note is a contradiction only in a pure tiers programme.
  assert.match(app, /tierPointPricedBenefitV238=\(line\)=>loyaltySelectionV230==='tiers'&&/);
});

test('V240 the wallet shows the ladder and the rewards together', () => {
  // The ladder hides ONLY in redeem; the rewards list is replaced ONLY in tiers.
  assert.match(app, /if\(String\(tier\.points_mode\|\|''\)==='redeem'\)\{\s*\n\s*return '';/);
  /* V241: the catalog became an object {rewards, points_mode} because appending the mode to
     the rewards ARRAY made data.points_mode unreadable — the wallet now reads a shape-tolerant
     walletPointsModeV241 and the gate fires on it. */
  assert.match(app, /if\(walletPointsModeV241==='tiers'\)\{/);
  assert.match(app, /Array\.isArray\(data\?\.rewards\)\?data\.rewards:\[\]/);
  // And a customer in 'both' is told the two are independent.
  assert.match(app, /bothNoteV240=String\(tier\.points_mode\|\|''\)==='both'/);
  assert.match(app, /Visits move you up\. Points stay yours to spend\./);
});

test('V240 the overview can show two live models at once', () => {
  assert.match(app, /liveLoyaltyModelKeysV240=liveLoyaltyModelV235==='both'\?\['redeem','tiers'\]:\[liveLoyaltyModelV235\]/);
  assert.match(app, /:!liveLoyaltyModelKeysV240\.includes\(key\)\?\['Off','off'\]/);
  assert.match(app, /Points redemption and Tiered membership are both live/);
  // The stamp card is still exclusive with the points engine — 'both' never marks it live.
  assert.doesNotMatch(app, /liveLoyaltyModelKeysV240=liveLoyaltyModelV235==='both'\?\[[^\]]*'stamps'/);
  assert.match(app, /data-points-mode-v229="both"/, 'the first-run chooser offers it too');
});

test('V241 the catalog payload is an object and the wallet tolerates both shapes', () => {
  /* Found verifying the owner's $10 scenario: jsonb array || object APPENDS, so the V230 mode
     marker was an extra array element the client could never read as data.points_mode. */
  const wallet = app.slice(app.indexOf('const loadRewards=async()=>'), app.indexOf('const redemptionEnabled='));
  assert.match(wallet, /walletCatalogV241=\(Array\.isArray\(data\)\?data:\(Array\.isArray\(data\?\.rewards\)\?data\.rewards:\[\]\)\)/);
  // Phantom entries (objects with no name) can never render as rewards again.
  assert.match(wallet, /filter\(item=>item&&typeof item==='object'&&\(item\.customer_name\|\|item\.name\)\)/);
  // The old array shape still yields a mode during the deploy window.
  assert.match(wallet, /'points_mode' in item&&!\('cost_points' in item\)/);
  assert.match(wallet, /const catalog=walletCatalogV241;/);
});
