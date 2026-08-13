/* V306 — two production defects in the Programmes setup wizard (growSetupWizardV301), both of
   them about what crosses a boundary rather than about what the wizard renders.

   1. A STALE points_mode blocked every stamp redemption. targetPointsModeV303 mapped the Stamp
      card to null, and applyPointsModeV303 reads a falsy target as "no change" — so a firm that
      had run Tiered membership (businesses.points_mode='tiers') and switched to a stamp card kept
      'tiers'. The V229 gate inside customer_create_redemption_intent_v89 refuses ALL redemption
      under 'tiers' and the customer 'rewards' capability stays false, so nothing that firm's
      customers collected could ever be claimed. Stamps target 'redeem' instead: it is what the
      V229 backfill gave every firm, on a stamp firm it means "what you collect can be spent", it
      passes the server gate, and it keeps coalesce(points_mode,'tiers')='tiers' FALSE so a tier
      ladder left over from a previous model cannot resurface on the customer page.

   2. An ILLEGAL tier_basis, and silently downgraded ladders. The DB CHECK — on loyalty_programs,
      loyalty_program_versions and the draft alike — allows only visits|spend|points_earned, while
      the wizard radio speaks visits|points. The reads compared the STORED value against 'points',
      which 'points_earned' never equals, so a points-earned ladder was read back as 'visits' and
      written back as one (production holds an open draft on 'points_earned' that this destroys);
      and the writes sent the radio key straight through, where 'points' violates the CHECK and the
      save fails outright. Two boundary translators, applied at the two reads and the two writes. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
};
const wizard = section('async function growSetupWizardV301(', 'function growPublishFieldRowsV170(');

test('V306 the Stamp card targets a points_mode that lets a stamp be redeemed', () => {
  assert.match(wizard, /const targetPointsModeV303=\(\)=>state\.pick==='stamps'\?'redeem':state\.pick;/);
  /* The old form must be GONE from the whole file, not merely absent from the wizard: a second
     copy of the mapping is how the fix would ship half-applied. */
  assert.doesNotMatch(app, /state\.pick==='stamps'\?null:state\.pick/);
  /* And the reason the null was fatal, pinned so it cannot be re-introduced as "harmless": a falsy
     target is still the early return that means "leave the live column alone". */
  assert.match(wizard, /if\(!target\|\|target===S\.biz\?\.points_mode\)\{state\.modeError='';if\(fromRetry\)render\(\);return true\}/);
  // The write itself is unchanged — one column on businesses, after publish.
  assert.match(wizard, /sb\.from\('businesses'\)\.update\(\{points_mode:target\}\)\.eq\('id',S\.biz\.id\)/);
});

test('V306 the Go-live step names the mode change the stamp card now makes', () => {
  /* pointsModeChangesV303() is TRUE for a stamp firm that was not already on 'redeem', so the
     step must state it. Falling through to the redeem sentence would have told a stamp firm about
     tiers it is no longer running; saying nothing would have been the old, wrong claim that
     choosing stamps leaves points_mode untouched. */
  assert.match(wizard, /:state\.pick==='stamps'\?'Customers switch to the stamp card\./);
  assert.match(wizard, /Customers switch to the stamp card\.[^']*stays saved/);
  assert.match(wizard, /const pointsModeChangesV303=\(\)=>\{\s*\r?\n?\s*const target=targetPointsModeV303\(\);\s*\r?\n?\s*return Boolean\(target&&target!==S\.biz\?\.points_mode\);/);
});

test('V306 tier_basis crosses the DB boundary through two translators', () => {
  assert.match(wizard, /const tierBasisFromDbV306=db=>\{const v=String\(db\|\|'visits'\);return v==='points_earned'\?'points':v==='spend'\?'spend':'visits'\};/);
  assert.match(wizard, /const tierBasisToDbV306=ui=>ui==='points'\?'points_earned':ui;/);
});

test('V306 both READ sites translate DB→UI, so a points_earned ladder is not downgraded', () => {
  assert.match(wizard, /const initialTierBasisV305=tierBasisFromDbV306\(base\?\.tier_basis\);/);
  assert.match(wizard, /tierBasis:tierBasisFromDbV306\(base\?\.tier_basis\),/);
  /* The comparison that collapsed 'points_earned' (and 'spend') to 'visits' is gone. Both sites
     read base?.tier_basis, so the old expression must not survive anywhere in the file. */
  assert.doesNotMatch(app, /String\(base\?\.tier_basis\|\|'visits'\)==='points'/);
});

test('V306 both WRITE sites translate UI→DB, so no save carries a CHECK-violating value', () => {
  assert.match(wizard, /if\(model==='points_tiers'&&state\.tierBasis\)row\.tier_basis=tierBasisToDbV306\(state\.tierBasis\);/);
  assert.match(wizard, /const basisResult=await runSaveV304\(\(\)=>saveDraft\(\{tier_basis:tierBasisToDbV306\(state\.tierBasis\)\}\)\);/);
  // The untranslated forms are the actual production failures — neither may exist anywhere.
  assert.doesNotMatch(app, /row\.tier_basis=state\.tierBasis/);
  assert.doesNotMatch(app, /saveDraft\(\{tier_basis:state\.tierBasis\}\)/);
  /* And those two are the ONLY places the wizard writes the column, so the translators cover the
     whole boundary rather than the two sites that happened to be reported. Comments are stripped
     first: the prose above each write names the column too. */
  const code = wizard.replace(/\/\*[\s\S]*?\*\//g, '');
  const writes = [...code.matchAll(/tier_basis[:=]/g)].map(match => match.index);
  assert.equal(writes.length, 2, `the wizard writes tier_basis in exactly two places (found ${writes.length})`);
  // Both of them through the translator, with nothing between the key and the call.
  assert.equal([...code.matchAll(/tier_basis[:=]tierBasisToDbV306\(/g)].length, 2,
    'and both go through tierBasisToDbV306');
});

test('V306 the radio still offers exactly visits and points — spend stays a deep-editor concern', () => {
  /* No production firm is on 'spend', and a third radio for it would be a new question on a step
     built to ask one. It survives instead: tierBasisFromDbV306 passes it through, tierBasisToDbV306
     passes it back, so it round-trips untouched and only an actual click moves a firm off it. */
  const climb = app.slice(app.indexOf('const GROW_SETUP_CLIMB_V305=['),
    app.indexOf('const GROW_SETUP_MODELS_V303=['));
  assert.match(climb, /\['visits','Visits',/);
  assert.match(climb, /\['points','Points earned',/);
  assert.equal(climb.match(/\['[a-z_]+','/g).length, 2, 'exactly two options');
  assert.ok(!/'spend'/.test(climb), 'and no spend option');
  // The click handler stays in UI space, mapping every press to one of those two keys.
  assert.match(wizard, /state\.tierBasis=button\.dataset\.growSetupBasisV305==='points'\?'points':'visits';/);
});
