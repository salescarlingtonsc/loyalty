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

test('V306/V314 the Stamp card reaches an engine that lets a stamp be redeemed', () => {
  /* V314 (W6 increment 1) SUPERSEDES V306's fix rather than reverting it. V306's defect was that
     the stamp card left businesses.points_mode on a stale 'tiers', which the V229 gate read as
     "points are for membership" and used to refuse every redemption. After the switchboard
     inversion there is no points_mode to leave stale: the card turns the STAMPS programme on and
     points/tiers off, and the redemption gate asks the spine. The V306 defect is closed by
     construction, and this pin now guards the mapping that replaced it. */
  /* V314 REMEDIATION (2026-08-14): the mapping is at MODULE scope now, not inside the wizard. The
     Grow editor's four-way toggle and both publish routes read the SAME table, which is what
     stopped them lying; pinning it against the wizard slice would re-authorise a per-door copy. */
  assert.match(app, /const PROGRAMME_SWITCHES_V314=\{\s*\r?\n?\s*redeem:\{points:true,tiers:false\},\s*\r?\n?\s*tiers:\{points:false,tiers:true\},\s*\r?\n?\s*both:\{points:true,tiers:true\},\s*\r?\n?\s*stamps:\{stamps:true,points:false,tiers:false\}\s*\r?\n?\s*\};/);
  /* Both older forms must be GONE from the WHOLE file, not merely absent from the wizard: a
     surviving copy of either mapping is how a fix ships half-applied. */
  assert.doesNotMatch(app, /state\.pick==='stamps'\?null:state\.pick/);
  assert.doesNotMatch(app, /state\.pick==='stamps'\?'redeem':state\.pick/);
  // No writer anywhere in the wizard may touch the frozen column again.
  assert.doesNotMatch(wizard, /points_mode:/);
  // The write is one owner-gated RPC, after publish, reached through the one shared writer.
  assert.match(app, /sb\.rpc\('set_programmes_v314',\{/);
  /* W6 increment 2: the wizard hands the writer a SWITCH SET, not a model key. state.pick is gone
     with the exclusive pick it named — the switchboard can express points AND stamps, which no
     model key spells — and the mapping table above survives for the three surfaces that genuinely
     still offer one of four. */
  assert.match(wizard, /writeProgrammeSwitchesV314\(S\.biz\.id,\{\.\.\.state\.switches\},/);
  assert.doesNotMatch(app, /state\.pick/);
});

test('V314 the Go-live step no longer narrates a frozen column', () => {
  /* V306 made the stamp card state its own mode-change sentence, because it MOVED points_mode.
     V314 froze that column, so a sentence conditioned on it would be narrating a value nothing
     writes — stale for exactly the owners who switch. The whole modeChangeLineV303 family is
     deleted here and rebuilt against the four spine flags in increment 2. The undeclared-identifier
     hazard is what these three assertions actually guard: a deleted declaration with a surviving
     reference passes `node --check` and the entire suite, then crashes in production. */
  for (const gone of ['modeChangeLineV303', 'pointsModeChangesV303',
                      'targetPointsModeV303', 'applyPointsModeV303']) {
    // A declaration OR a call — prose in a comment is allowed to keep naming what was removed.
    assert.doesNotMatch(app, new RegExp(`(const|function)\\s+${gone}\\b`), `${gone} is declared`);
    assert.doesNotMatch(app, new RegExp(`${gone}\\s*\\(`), `${gone} is still called`);
  }
  // The retry control and its honest wording survive — the switch really can fail after publish.
  assert.match(wizard, /id="growSetupModeRetryV303"/);
  assert.match(wizard, /applyProgrammeSwitchesV314\(true\)/);
});

test('V306 tier_basis crosses the DB boundary through two translators', () => {
  /* W6 increment 2 (OWNER AMENDMENT 2026-08-14) changes ONE thing in the read translator: the
     fallback for a firm with NOTHING stored moves from 'visits' to 'points', because points-earned
     is the standard the wizard now suggests for a NEW ladder. Every stored value still round-trips
     to itself — that is what the three explicit branches are for, and it is why the amendment's
     "never silently downgrade" survives a changed default. */
  assert.match(wizard, /const tierBasisFromDbV306=db=>\{/);
  assert.match(wizard, /if\(v==='points_earned'\)return 'points';/);
  assert.match(wizard, /if\(v==='spend'\)return 'spend';/);
  assert.match(wizard, /if\(v==='visits'\)return 'visits';/);
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
    app.indexOf('function mergeRewardsV302('));
  assert.match(climb, /\['visits','Visits',/);
  assert.match(climb, /\['points','Points earned',/);
  assert.equal(climb.match(/\['[a-z_]+','/g).length, 2, 'exactly two options');
  assert.ok(!/'spend'/.test(climb), 'and no spend option');
  // The click handler stays in UI space, mapping every press to one of those two keys.
  assert.match(wizard, /state\.tierBasis=button\.dataset\.growSetupBasisV305==='points'\?'points':'visits';/);
});
