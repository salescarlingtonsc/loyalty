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

/* V258: V256 DROPPED the two v239 triggers in production (verified: pg_trigger has no v239_*
   rows). The owner's ruling replaced the old invariant — a tier measured by 'points_earned'
   sums points_ledger entry_type='earn', i.e. LIFETIME points earned, which redemption never
   reduces, so it may coexist with points_mode='both'. The assertions below still pin the v239
   migration FILE, which is immutable history; the live rule is pinned by the client tests
   below and by tests/business-ui/v258-loyalty-setup-friction.test.mjs. */
test('V240 the v239 migration file records the rule V256 later removed', () => {
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
  /* nestly_v567: the invented 'classic' placeholder is gone — an unreadable model normalises to
     '' and fails closed to the points/tiers branch, instead of a model nobody saved. */
  assert.match(app, /liveLoyaltySelectionV235=normaliseLoyaltyModelV375\(p\?\.loyalty_model\)==='stamps'\?'stamps'\s*\n\s*:loyaltySelectionForModeV240/);
  // V258: the line no longer names a basis, because every basis is now selectable under 'both'.
  assert.match(app, /both:\{name:'Points \+ tiers',line:'Customers spend points on rewards, and separately climb tiers — the two never affect each other\.'\}/);
  assert.match(app, /\$\{\['redeem','tiers','both','stamps'\]\.map\(key=>/);
  // The group label no longer claims exclusivity, because it is no longer true.
  assert.doesNotMatch(app, /aria-label="Loyalty model — only one is live at a time"/);
});

test('V240 both renders the catalogue AND the ladder', () => {
  const site = app.slice(app.indexOf("?`<b>Tiers — your loyalty model</b>"), app.indexOf('applyGrowLoyaltyEditorIsolationV139', app.indexOf("?`<b>Tiers — your loyalty model</b>")));
  const both = site.slice(site.indexOf("loyaltySelectionV230==='both'"));
  assert.match(both, /rewardRows\('Your rewards'\)\}\$\{tierRows\(\)\}/,
    'both must reuse the same composables, not fork them');
  // V258: the sentence reads the firm's own basis instead of asserting visits.
  assert.match(both, /Both run together: points buy rewards, and tiers count lifetime \$\{esc\(tierBasisWordV235\)\}\./);
  // Pure tiers still hides rewards; pure redeem still hides tiers.
  assert.match(site, /Point rewards are off in this model/);
  assert.match(site, /Tiers are off in this model/);
});

/* V258 (owner item 8) inverts this test: the restriction it used to pin is the bug. */
test('V240/V258 the tier basis always offers lifetime points earned', () => {
  assert.doesNotMatch(app, /tierBasisAllowsPointsV240/);
  assert.doesNotMatch(app, /tierBasisValueV240/);
  // The stored basis is shown as stored — nothing is rewritten on the way to the screen.
  assert.match(app, /const tierBasisValueV258=p\?\.tier_basis\|\|'visits';/);
  // The option is unconditional now, not gated behind a mode test.
  assert.match(app, /<option value="points_earned" \$\{tierBasisValueV258==='points_earned'\?'selected':''\}>Lifetime points earned<\/option>/);
  // The old helper line was inaccurate; the new one explains why the pairing is coherent.
  assert.doesNotMatch(app, /Tiers count visits so points stay free to spend\./);
  assert.match(app, /Tiers count lifetime points earned — spending points never lowers a tier\./);
});

test('V240/V258 the save path writes the chosen basis unchanged', () => {
  const save = app.slice(app.indexOf("const loyaltySave=$('lsave')"), app.indexOf("if(draftVersionId){\n      toast('Grow draft saved"));
  assert.match(save, /targetModeV230=loyaltySelectionV230==='tiers'\?'tiers':loyaltySelectionV230==='both'\?'both':'redeem'/);
  // V258: no coercion at all — 'points_earned' reaches the server exactly as chosen.
  assert.doesNotMatch(save, /basisV240/);
  assert.match(save, /row\.tier_basis=\$\('ltb'\)\.value;/);
  /* The draft save (carrying tier_basis) precedes the live switch — the order the database
     requires. V314 (W6i1, 2026-08-14): the switch is public.set_programmes_v314 on the four-row
     spine, not a businesses.points_mode UPDATE, because that column is frozen behind a tripwire
     that silently pins any write. The ordering rule is untouched. */
  assert.ok(save.indexOf("save_loyalty_config_draft") < save.indexOf("writeProgrammeSwitchesV314(S.biz.id,loyaltySelectionV230,"));
  // V258: the 23514 branch is unreachable since V256 dropped the trigger, so it is gone from
  // both write paths — a dead branch can only ever mislead.
  assert.doesNotMatch(save, /modeError\.code==='23514'/);
  assert.doesNotMatch(app, /measure its tiers in points\/i\.test/);
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
  // V258: the note reads the firm's real basis rather than asserting visits.
  assert.match(app, /bothNoteV258=String\(tier\.points_mode\|\|''\)==='both'/);
  assert.match(app, /Points you earn move you up — spending them never lowers your tier\./);
  assert.match(app, /Visits move you up\. Points stay yours to spend\./);
});

test('V240 the overview can show two live models at once', () => {
  assert.match(app, /liveLoyaltyModelKeysV240=liveLoyaltyModelV235==='both'\?\['redeem','tiers'\]:\[liveLoyaltyModelV235\]/);
  assert.match(app, /:!liveLoyaltyModelKeysV240\.includes\(key\)\?\[STATUS_WORDS\.off,'off'\]/);
  /* V296 retarget: that sentence was otherModelLiveV235()'s output, printed as the SUBTITLE of a
     pending card; the owner struck those subtitles out ("X NO — not linked to point") on
     2026-08-12 and the helper went with them. What this test is really about — 'both' making two
     tiles live at once — is asserted directly on the tile status instead, which is stronger. */
  assert.doesNotMatch(app, /otherModelLiveV235\(\)\?/);
  assert.match(app, /\{key:'points',icon:'star',title:'Point system'/);
  assert.match(app, /summary:!liveLoyaltyModelKeysV240\.includes\('redeem'\)\?''/);
  assert.match(app, /summary:!liveLoyaltyModelKeysV240\.includes\('tiers'\)\?''/);
  // The stamp card is still exclusive with the points engine — 'both' never marks it live.
  assert.doesNotMatch(app, /liveLoyaltyModelKeysV240=liveLoyaltyModelV235==='both'\?\[[^\]]*'stamps'/);
  /* V314 (W6i1, 2026-08-14): the first-run chooser is DELETED — its three cards wrote the frozen
     businesses.points_mode column and could only ever look like they worked. 'both' is still one
     of the four models a firm can pick; the surfaces that offer it are the setup wizard's step 1
     and the Grow editor's four-way toggle, and both map it through the same switch set. */
  assert.doesNotMatch(app, /data-points-mode-v229="both"/);
  assert.match(app, /both:\{points:true,tiers:true\}/, 'the switch mapping still offers both');
  assert.match(app, /\['redeem','tiers','both','stamps'\]\.map\(key=>/, 'and the editor toggle does too');
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
