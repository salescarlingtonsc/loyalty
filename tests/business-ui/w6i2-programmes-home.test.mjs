/* W6 INCREMENT 2 — THE FOUR-SWITCH PROGRAMMES HOME.
 *
 * Wave-keyed, not vNNN: `v315`-`v318` are held by a parallel session's prospecting work and
 * `nestly_vNNN` is a shared namespace. This increment ships no migration, so it claims no number.
 *
 * Increment 1 made public.business_programmes the switching authority and public.set_programmes_v314
 * its one writer. What it deliberately did NOT ship was a way for an owner to SEE or SET the four
 * switches: the wizard still offered one of four exclusive models, which is a shape the spine can no
 * longer be described by. This file pins the surface that closes that gap, plus the three things the
 * owner amendment of 2026-08-14 protects and one decision (D3) whose server half does not exist yet.
 *
 * The four claims, and why each is a SOURCE pin rather than a render test:
 *
 *   A. FOUR INDEPENDENT SWITCHES. The failure this guards is subtle and total: a control that looks
 *      like a switch but behaves like a radio. Nothing about the rendered pixels distinguishes them
 *      — the difference is one line in the click handler and one ARIA role, so those are what is
 *      pinned. A radiogroup PROMISES the reader that picking one un-picks the others; after v314 that
 *      promise is a lie, and a lie the owner acts on is worse than a missing control.
 *
 *   B. THE OWNER AMENDMENT SURVIVES. Three separate things the W6 design contract had deleted or let
 *      fall away, and the amendment restored by name: the tier BASIS CHOICE (visits or points-earned,
 *      points-earned suggested for a NEW ladder only), every points expiry mode (including yearly as
 *      fixed+365 and inactivity), and rung-level windows staying reachable. A default flipped without
 *      the "stored values round-trip" guard below IS the silent downgrade the amendment forbids.
 *
 *   C. D3's MEMBER-MOVEMENT PREVIEW, in two halves that fail independently. WHAT changes is computed
 *      from data the screen already holds, so the confirmation gate never depends on a server. HOW
 *      MANY members move needs a per-client aggregation the browser cannot do — it is read behind a
 *      capability check from a key that DOES NOT EXIST YET, and an absent key must produce an honest
 *      sentence rather than a zero.
 *
 *   D. W4c's member QR, shipped switched OFF. Its two RPCs are unshipped, and naming an ungranted
 *      function in the bundle is refused on purpose by the writer registry and the v21 allowlist.
 *
 * The wizard-suite half of this contract is tests/business-ui/v301-programmes-setup-wizard.test.mjs,
 * rewritten red-first in the same change. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const html = readFileSync(join(root, 'app', 'index.html'), 'utf8');

const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
};
/* Comments name every deleted symbol on purpose — that is how a later reader learns why it is gone
   — so every "no such thing survives" assertion runs against code with the prose removed. */
const stripComments = source => source
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/^\s*\/\/.*$/gm, '');
const code = stripComments(app);
const wizard = section('async function growSetupWizardV301(', 'function growPublishFieldRowsV170(');
const wizardCode = stripComments(wizard);
const grow = section('async function growPage(', '/* ---------- Bring-back playbooks');
const scanner = section('function redemptionPayloadFromQr(', 'function redemptionTokenFromQr(');

/* ================= A. four independent switches ================= */

test('W6I2 A1 the switchboard is FOUR switches, not one of four models', () => {
  /* The ruling, in one attribute. role="switch" with aria-checked says "this thing is on or off";
     role="radio" inside a radiogroup says "this thing is on and the others are not". After v314 the
     spine can hold points AND stamps, so only the first is true. */
  assert.match(wizard, /role="group" aria-label="Programmes"/);
  assert.match(wizard, /role="switch" aria-checked="\$\{on\}" data-grow-setup-switch-w6i2="\$\{esc\(kind\)\}"/);
  assert.doesNotMatch(wizardCode, /role="radiogroup" aria-label="Programme model"/);
  assert.doesNotMatch(wizardCode, /data-grow-setup-model-v303/);
  // Four kinds, exactly the four the RPC accepts. A fifth would fail with 22023 at publish time,
  // after the owner has already committed.
  assert.match(code, /const PROGRAMME_KINDS_W6I2=\['points','tiers','stamps','referral'\];/);
  const table = app.slice(app.indexOf('const GROW_SETUP_SWITCHES_W6I2=['),
    app.indexOf('const GROW_SETUP_SWITCH_FOOTER_W6I2='));
  assert.deepEqual([...table.matchAll(/\['(points|tiers|stamps|referral)',/g)].map(m => m[1]),
    ['points', 'tiers', 'stamps', 'referral']);
  /* Low-literacy-first (standing rule): a pictogram, a label of at most three words, one plain
     education line, and the ON/OFF state as a WORD rather than a colour — colour alone is not a
     state for a counter hand who may not read English fluently. */
  for (const title of ['Points & gifts', 'Tier membership', 'Stamp card', 'Referral'])
    assert.ok(table.includes(`','${title}',`), `${title} must be one of the four`);
  assert.ok([...table.matchAll(/','([A-Za-z][^']*)',\n/g)].every(m => m[1].split(/\s+/).length <= 3),
    'every switch label is at most three words');
  assert.match(wizard, /\$\{CUI\.icon\(icon,\{size:26\}\)\}/);
  assert.match(wizard, /<span class="pill \$\{on\?'on':'off'\}" data-grow-setup-switch-state-w6i2="\$\{on\?'on':'off'\}">\$\{on\?'ON':'OFF'\}<\/span>/);
});

test('W6I2 A2 flipping one switch leaves the other three exactly as they were', () => {
  /* THE assertion of the wave. An exclusive control wearing switch clothing would pass every other
     test in this file; it would fail only here, because only here is the OTHER three's fate stated. */
  assert.match(wizard, /state\.switches=\{\.\.\.state\.switches,\[kind\]:state\.switches\[kind\]!==true\};/);
  const handler = wizard.slice(wizard.indexOf("host.querySelectorAll('[data-grow-setup-switch-w6i2]')"),
    wizard.indexOf("host.querySelectorAll('[data-grow-setup-basis-v305]')"));
  assert.ok(handler.length > 100, 'the toggle handler was found and sliced');
  // Nothing is written on screen 0 — the switch reaches the engine at Go-live and nowhere else.
  assert.doesNotMatch(stripComments(handler), /sb\.rpc|sb\.from|saveDraft|writeProgrammeSwitches/);
  // Only ONE switch key is touched per press: a handler that rebuilt the object from a model key
  // would read as innocent and behave exclusively.
  assert.equal([...handler.matchAll(/state\.switches=/g)].length, 1);
});

test('W6I2 A3 the switch SET reaches public.set_programmes_v314 whole, once, after publish', () => {
  /* v314's writer accepts either a legacy model key or an explicit set. The switchboard is the one
     caller that produces a state no model key spells, and it must send all four kinds: an omitted
     key leaves that spine row at whatever it was, so a switch the owner turned OFF would stay on. */
  assert.match(code, /const base=typeof selection==='string'\s*\r?\n?\s*\?PROGRAMME_SWITCHES_V314\[selection\]/);
  assert.match(code, /\?Object\.fromEntries\(PROGRAMME_KINDS_W6I2\.filter\(kind=>kind in selection\)/);
  assert.match(wizard, /await writeProgrammeSwitchesV314\(S\.biz\.id,\{\.\.\.state\.switches\},\s*\r?\n?\s*\{paused:state\.keepPaused===true,key:state\.switchKeyV314\}\)/);
  // AFTER publish, never before — the V230/V303 discipline v314 preserved verbatim.
  const publishStep = wizard.slice(wizard.indexOf('const activeResult=await saveDraft({active:'));
  assert.ok(publishStep.indexOf('publish_loyalty_config') < publishStep.indexOf('applyProgrammeSwitchesV314(false)'),
    'the switches may only be applied AFTER the publish they belong with');
  // And the frozen column is still untouched by every door, including this new one.
  assert.equal([...code.matchAll(/\.update\(\{\s*points_mode/g)].length, 0);
});

test('W6I2 A4 the rail is composed from the switches, in customer-facing order', () => {
  /* Three fixed step lists could each only be right for one subset of sixteen. Composing means a
     programme turned off mid-rail takes its screens with it and the percentage recomputes, with no
     number written down anywhere in the closure. */
  assert.match(code, /const GROW_SETUP_RAIL_W6I2=\[/);
  const rail = app.slice(app.indexOf('const GROW_SETUP_RAIL_W6I2=['),
    app.indexOf('const GROW_SETUP_SECTOR_DEFAULTS_W6I2='));
  assert.deepEqual([...rail.matchAll(/^\s*\['(stamps|points|tiers|referral)',\[/gm)].map(m => m[1]),
    ['stamps', 'points', 'tiers', 'referral'], 'STAMPS → POINTS & GIFTS → TIER → REFERRAL');
  assert.match(wizard, /if\(state\.switches\[programme\]!==true\)return;/);
  assert.match(wizard, /const railCountW6I2=\(\)=>railW6I2\(\)\.length;/);
  assert.match(wizard, /const railPercentW6I2=\(\)=>\{/);
  assert.match(wizard, /Step \$\{state\.step\} of \$\{railCountW6I2\(\)\} · \$\{esc\(railStepW6I2\(\)\.label\)\}/);
  // Zero switched on: the rail is screen 0 + Go-live, and Publish is refused in words.
  assert.match(wizard, /const anySwitchOnW6I2=\(\)=>PROGRAMME_KINDS_W6I2\.some\(kind=>state\.switches\[kind\]===true\);/);
  assert.match(wizard, /\|\|!anySwitchOnW6I2\(\)/);
  assert.match(wizard, /Nothing is turned on, so there is nothing to publish\./);
});

test('W6I2 A5 points and stamps can run together, and one version row carries both', () => {
  /* The engine proof, client side. v314 dropped `lp.kind` from the earn loop's points branch, so a
     single loyalty_program_versions row carrying BOTH stamp_per_cents and earn_points_per_dollar is
     exactly what a points+stamps firm needs — the loop reads the spine, then this row's two
     numbers, and never loyalty_model. A row that wrote one field OR the other would leave one of
     the two switched-on programmes earning nothing, silently. */
  assert.match(wizard, /if\(state\.switches\.stamps===true\)row\.stamp_per_cents=Math\.round\(state\.stampSpend\*100\);/);
  assert.match(wizard, /if\(model!=='stamps'\)row\.earn_points_per_dollar=state\.earn;/);
  // loyalty_model is a SETTINGS discriminator now: stamps alone is a stamps firm, otherwise points.
  assert.match(wizard, /if\(state\.switches\.stamps===true&&state\.switches\.points!==true&&state\.switches\.tiers!==true\)\s*\r?\n?\s*return 'stamps';/);
  // 'classic' survives untouched — orphaning the fixed redeem pair breaks that firm's one reward.
  assert.match(wizard, /return baseModel&&baseModel!=='stamps'\?baseModel:'points_tiers';/);
  // Each screen speaks its OWN programme's engine, which is what lets both rails coexist.
  assert.match(wizard, /const familyW6I2=\(\)=>railStepW6I2\(\)\.programme==='stamps'\?'stamps':'points';/);
  assert.doesNotMatch(code, /state\.family/);
});

test('W6I2 A6 a tile hands over a programme to turn ON, never a model to switch TO', () => {
  assert.match(grow, /const growSetupKindForTileW6I2=key=>key==='stamps'\?'stamps':key==='tiers'\?'tiers':'points';/);
  assert.match(grow, /pendingGrowSetupModelV303=\{kind:growSetupKindForTileW6I2\(tile\.dataset\.growTopicV229\),/);
  assert.match(wizard, /if\(handoffKindW6I2\)set\[handoffKindW6I2\]=true;/);
  /* ON only. The deleted helper answered "which of four exclusive models is this card", so opening
     the Stamp card tile at a points firm proposed the live points programme off. */
  assert.doesNotMatch(code, /growSetupModelForTileV303/);
  assert.match(grow, /if\(label==='Off'\)return 'Turn on →';/);
  assert.doesNotMatch(code, /'Switch to this →'/);
});

test('W6I2 A7 switch state is READ from the spine, and sector defaults cannot overwrite a decision', () => {
  // Spine first (v314's authority), frozen legacy columns as the stale-but-not-invented fallback.
  assert.match(wizard, /const rows=programmeSpineRowsV314\(\);/);
  assert.match(wizard, /if\(rows\)return Object\.fromEntries\(PROGRAMME_KINDS_W6I2\s*\r?\n?\s*\.map\(kind=>\[kind,programmeSpineOnV314\(kind\)===true\]\)\);/);
  // Sector defaults apply ONLY when nothing at all is on — never over an existing answer.
  assert.match(wizard, /if\(PROGRAMME_KINDS_W6I2\.some\(kind=>set\[kind\]===true\)\)return set;/);
  const defaults = app.slice(app.indexOf('const GROW_SETUP_SECTOR_DEFAULTS_W6I2={'),
    app.indexOf('const GROW_SETUP_CLIMB_V305='));
  for (const [sector, kinds] of [['fnb', "['stamps']"], ['fitness', "['tiers','referral']"],
    ['retail', "['points']"], ['salon', "['points','tiers']"]])
    assert.ok(defaults.includes(`${sector}:${kinds}`), `${sector} default must be ${kinds}`);
  // The browser still only ever READS the spine table; the RPC is the one door.
  assert.deepEqual([...new Set([...code.matchAll(/sb\.from\('business_programmes'\)\.([a-z]+)\(/g)]
    .map(m => m[1]))], ['select']);
});

/* ================= B. the owner amendment of 2026-08-14 ================= */

test('W6I2 B1 the tier basis is a visible CHOICE, and points-earned is only a SUGGESTION', () => {
  /* The W6 design contract §1.3 deleted this control and forced every ladder onto points earned.
     The amendment overrode it in as many words. The distinction that makes the amendment true is
     narrow and mechanical: the fallback changes, the stored values do not. */
  assert.match(code, /const GROW_SETUP_CLIMB_V305=\[\s*\r?\n?\s*\['points','Points earned',/);
  assert.match(code, /\['visits','Visits',/);
  assert.match(wizard, /const tierBasisStoredW6I2=\['visits','spend','points_earned'\]\.includes\(String\(base\?\.tier_basis\|\|''\)\);/);
  assert.match(wizard, /key==='points'&&!tierBasisStoredW6I2\?'<span class="muted small"><b>Suggested<\/b><\/span>':''/);
  // Every stored basis round-trips to itself. This is the "never silently downgrade" guarantee.
  assert.match(wizard, /if\(v==='points_earned'\)return 'points';/);
  assert.match(wizard, /if\(v==='spend'\)return 'spend';/);
  assert.match(wizard, /if\(v==='visits'\)return 'visits';/);
  /* ...and the FALLBACK — the only thing the amendment changed — is points, for a firm with
     nothing stored. Pinned adjacent to the three round-trips above on purpose: a revert of this
     one line is the whole difference between "suggested" and "silently downgraded", and it is
     invisible to every other assertion in this file. */
  assert.match(wizard, /if\(v==='visits'\)return 'visits';\s*\r?\n?\s*return 'points';/);
  assert.match(wizard, /const tierBasisToDbV306=ui=>ui==='points'\?'points_earned':ui;/);
  // 'spend' has no radio and keeps none: it is a deep-editor option the amendment preserves as-is.
  const climb = app.slice(app.indexOf('const GROW_SETUP_CLIMB_V305=['), app.indexOf('function mergeRewardsV302('));
  assert.ok(!/'spend'/.test(climb), 'spend must not become a wizard radio');
  // The Climbing screen is screen 1 of EVERY tier rail, not only a tiers-only one.
  assert.match(code, /\['tiers',\[\['climb','Climbing'\],\['tiers','Tiers'\]\]\]/);
});

test('W6I2 B2 the wizard produces exactly three rungs, Silver / Gold / Diamond (D7)', () => {
  assert.match(wizard, /const TIER_DEFAULTS_V303=\[\['Silver',0\],\['Gold',200\],\['Diamond',500\]\];/);
  assert.match(wizard, /const TIER_DEFAULTS_VISITS_W6I2=\[\['Silver',0\],\['Gold',5\],\['Diamond',15\]\];/);
  // A threshold means a different quantity under each basis, so the prefill does too.
  assert.match(wizard, /const tierDefaultsW6I2=\(\)=>tierBasisV303\(\)==='visits'\?TIER_DEFAULTS_VISITS_W6I2:TIER_DEFAULTS_V303;/);
  assert.equal([...wizard.matchAll(/\['Silver',0\]/g)].length, 2, 'three rungs, one table per basis');
  // PRODUCED, not offered — and only for a firm with NO ladder, so D7's "no retroactive
  // enforcement" holds and a tenant on six rungs stays on six.
  // W6 RISK C: "no ladder" now has to be DISTINGUISHED from "the ladder could not be read", so the
  // fail-closed guard is the first line of the function and the emptiness guard is the second. The
  // pin used to require them to be one line, which is the collapse itself. The behaviour is in
  // tests/business-ui/w6-risk-c-tier-read-envelope.test.mjs.
  assert.match(wizardCode, /const prefillTiersW6I2=\(\)=>\{\s*\r?\n?\s*if\(tiersUnreadableW6I2\(\)\)return false;\s*\r?\n?\s*if\(state\.switches\.tiers!==true\|\|state\.tiers\.length\)return false;/);
  assert.match(wizard, /state\.tiersDirty\.add\(id\);/);
  assert.equal([...wizard.matchAll(/if\(stepKindW6I2\(\)==='tiers'\)prefillTiersW6I2\(\);/g)].length, 2,
    'prefilled on arrival at the ladder screen and on a wizard that opens directly on it');
  // Bronze/Silver/Gold is gone. It disagreed with the ruling AND with the v148 seed.
  assert.doesNotMatch(code, /\['Bronze',0\]/);
});

test('W6I2 B3 every points expiry knob is reachable from the wizard', () => {
  /* "every expiry knob survives per-programme — points expiry in all its modes (e.g. yearly via
     expiry_days=365, inactivity)". Before this wave programRowV305 carried whatever was already
     stored straight through, so an owner who only used the wizard could not reach the knob at all.
     Surviving has to mean reachable. */
  assert.match(code, /\['points',\[\['earn','Earning'\],\['reward','Gifts'\],\['expiry','Expiry'\]\]\]/);
  assert.match(wizard, /const expiryStepHtmlW6I2=\(\)=>\{/);
  for (const mode of ['none', 'fixed', 'inactivity'])
    assert.match(wizard, new RegExp(`<option value="${mode}"\\$\\{state\\.expiryMode==='${mode}'`),
      `the ${mode} expiry mode must be offered`);
  // Yearly is fixed + 365, exactly as the amendment spells it — never a fourth mode.
  assert.match(wizard, /else if\(preset==='year'\)\{state\.expiryMode='fixed';state\.expiryDays=365\}/);
  assert.match(wizard, /else \{state\.expiryMode='inactivity';state\.expiryDays=365\}/);
  // Same days-required helper the deep editor uses, so the two surfaces cannot disagree.
  assert.match(wizard, /const needsDays=expiryModeRequiresDays\(state\.expiryMode\);/);
  assert.match(wizard, /if\(expiryModeRequiresDays\(state\.expiryMode\)&&!\(Number\(state\.expiryDays\)>0\)\)\{/);
  // It reaches the SAME programme row every other screen writes, so expiry can never disagree with
  // the earn rate it ships beside.
  assert.match(wizard, /expiry_mode:state\.expiryMode\};/);
  assert.match(wizard, /row\.expiry_days=row\.expiry_mode==='none'\?null:Math\.max\(1,Math\.round\(Number\(state\.expiryDays\)\|\|365\)\);/);
  // Rung-level effective/expiry windows keep their home, and both screens SAY where that is.
  assert.match(wizard, /each rung's start and end dates live under More reward settings\./);
  assert.match(wizard, /Rung start and end dates stay in the full editor under More reward settings\./);
  assert.match(app, /effective_from:tier\.effectiveFrom,expires_at:tier\.expiresAt\}/);
});

test('W6I2 B4 the referral rail writes referral_programs at Go-live, never on a screen Next', () => {
  /* public.referral_programs is a LIVE table, not part of the versioned draft. Writing it on Next
     would turn referrals on for real halfway through a setup the owner may walk away from — the
     exact reason the model switch has waited for publish since V230. */
  assert.match(code, /\['referral',\[\['referral','Referral'\]\]\]/);
  assert.match(wizard, /const referralStepHtmlW6I2=\(\)=>/);
  const referralBranch = wizard.slice(wizard.indexOf("if(kind==='referral')return withBusy"),
    wizard.indexOf("if(kind==='reward'||kind==='stampGift')return withBusy"));
  assert.ok(referralBranch.length > 80, 'the referral branch was found and sliced');
  assert.doesNotMatch(referralBranch, /sb\.rpc|sb\.from/);
  const switchApply = wizard.slice(wizard.indexOf('async function applyProgrammeSwitchesV314(fromRetry){'),
    wizard.indexOf('const programRowV305=model=>{'));
  assert.match(switchApply, /sb\.rpc\('save_referral_program',\{p_business:S\.biz\.id,/);
  /* The spine row and referral_programs.enabled must agree: the spine gates presentation and the
     engine's referral block still reads `enabled`, so a switch-on that left `enabled` false would
     be a programme that looks live and pays nothing. */
  assert.match(switchApply, /const referralWanted=state\.switches\.referral===true&&state\.keepPaused!==true;/);
  assert.match(switchApply, /p_enabled:referralWanted,/);
  // A no-op write is still a write, and this one lands on a live table.
  assert.match(switchApply, /if\(state\.referralDirty\|\|referralWanted!==referralWasOn\)\{/);
});

/* ================= C. D3, and the half of it the server has not shipped ================= */

test('W6I2 C1 a threshold or basis change NAMES what moves, from data already on the screen', () => {
  /* W6 RISK C: this pin used to require `(Array.isArray(liveTiers)?liveTiers:[])`, which is the
     null-collapse it was meant to protect — a failed read became an empty ladder and the gate below
     went silent for exactly the firms it could not see. The published ladder now arrives as a
     three-state envelope and this reader takes its rows; whether there IS a published ladder is
     asked through tiersUnreadableW6I2(), never through this list's length. */
  assert.match(wizard, /const publishedTiersW6I2=\(\)=>liveTiersW6I2\.rows/);
  assert.match(wizard, /const tierThresholdChangesW6I2=\(\)=>\{/);
  assert.match(wizard, /direction:draft\.threshold>live\.threshold\?'harder':'easier'/);
  assert.match(wizard, /return \{name:live\.name,from:live\.threshold,to:null,direction:'removed'\};/);
  /* The basis half compares against the PUBLISHED basis, never the draft's. Comparing against
     initialTierBasisV305 (the draft's basis at wizard open) made the gate intra-session only: a
     basis change saved into the draft by a previous session, or by the deep editor, published with
     no warning and no tick while still re-sorting every member. The threshold half above was
     already re-entry-safe by construction; this is the same comparison for the other half. */
  assert.match(wizard, /const publishedTierBasisW6I2=\['visits','spend','points_earned'\]\.includes\(String\(live\?\.tier_basis\|\|''\)\)/);
  assert.match(wizard, /const tierBasisChangedW6I2=\(\)=>publishedTierBasisW6I2!==null&&state\.tierBasis!==publishedTierBasisW6I2;/);
  // The gate is computed locally, so it never depends on a server answering.
  const compute = wizard.slice(wizard.indexOf('const publishedTiersW6I2='),
    wizard.indexOf('const tierMovementCountsW6I2='));
  assert.doesNotMatch(stripComments(compute), /sb\.rpc|sb\.from/);
  // Only a change that can move someone DOWN needs the tick — easier thresholds move people up.
  assert.match(wizard, /&&\(tierBasisChangedW6I2\(\)\|\|tierThresholdChangesW6I2\(\)\.some\(change=>change\.direction!=='easier'\)\);/);
});

test('W6I2 C2 D3 requires its own explicit tick, and it is not the advanced-rule tick', () => {
  /* Two admissions, two boxes. Collapsing them would let an owner who ticked "I have read the
     changes" also be recorded as having accepted a tier demotion they were never shown. */
  assert.match(wizard, /tierAck:false,/);
  assert.match(wizard, /id="growSetupTierAckW6I2"/);
  assert.match(wizard, /I understand members can move down a tier when I publish\./);
  assert.match(wizard, /const publishBlockedW6I2=\(\)=>stepKindW6I2\(\)==='live'/);
  assert.match(wizard, /&&\(\(state\.needAck&&!state\.ack\)\|\|\(tierMovementRiskW6I2\(\)&&!state\.tierAck\)\|\|!anySwitchOnW6I2\(\)/);
  assert.match(wizard, /id="growSetupNextV301"\$\{publishBlockedW6I2\(\)\?' disabled':''\}/);
  /* And the SAME predicate is re-checked inside the publish flow. A disabled attribute is a hint,
     not a guard: the error block's Retry button calls advance() straight back into the publish
     chain without ever consulting it. */
  assert.match(wizard, /if\(publishBlockedW6I2\(\)\)\{state\.error=publishBlockedReasonW6I2\(\);return render\(\)\}/);
  // Re-basing re-units every threshold, so the tick has to be re-earned.
  assert.match(wizard, /state\.tierAck=false;/);
  // The block appears on the ladder screen as information and on the gate as a gate.
  assert.match(wizard, /const tierMovementBlockW6I2=\(\{gate=false\}=\{\}\)=>\{/);
  assert.match(wizard, /\$\{tierMovementBlockW6I2\(\{gate:true\}\)\}/);
});

test('W6I2 C3 the movement COUNT is capability-checked and degrades to an honest sentence', () => {
  /* preview_publish_impact.tier_movements DOES NOT EXIST. The count needs a per-client tier-metric
     aggregation over every customer at the business — under 'visits' a visit count per client,
     under 'points_earned' a lifetime-earn sum — and paging either into the browser would silently
     under-count the moment a page limit clipped it. So it is read, not computed, and an absent key
     must never become a zero the owner would act on. */
  assert.match(wizard, /const tierMovementCountsW6I2=\(\)=>\{/);
  assert.match(wizard, /if\(!movements\|\|typeof movements!=='object'\)return null;/);
  assert.match(wizard, /if\(movements\.evaluated===false\)return \{evaluated:false,reason:String\(movements\.reason\|\|''\)\};/);
  assert.match(wizard, /How many members move is not counted yet on this workspace/);
  assert.match(wizard, /There are too many members to count the moves before publishing\./);
  assert.match(wizard, /\$\{counts\.down\} member\$\{counts\.down===1\?'':'s'\} would move down · \$\{counts\.up\} would move up\./);
  // Read when the gate PAINTS, not only when Publish is pressed — otherwise it is not a preview.
  const load = wizard.slice(wizard.indexOf('async function loadComparison(){'), wizard.indexOf('const readStepFields='));
  assert.match(load, /sb\.rpc\('preview_publish_impact',\{p_config_version_id:state\.versionId\}\)/);
  assert.match(load, /\.then\(response=>response\.error\?null:\(response\.data\|\|null\)\)\.catch\(\(\)=>null\)/);
  assert.match(load, /state\.impact=impact;/);
});

/* ================= D. W4c's member QR, shipped switched OFF ================= */

test('W6I2 D1 the counter parses a fourth code kind, and only a fourth', () => {
  /* nestly:member: is the only one of the four that settles nothing — it answers "who is standing
     in front of me". Keeping it in the SAME parser is the point: the counter must not have to know
     which of four codes a customer is holding before choosing a control. */
  assert.match(scanner, /const memberPrefixed=raw\.match\(\/\^nestly:member:\(\[A-Za-z0-9_-\]\{20,512\}\)\$\/i\);/);
  assert.match(scanner, /if\(memberPrefixed\)return \{kind:'member',token:memberPrefixed\[1\]\};/);
  for (const kind of ['redemption', 'growth', 'promotion'])
    assert.match(scanner, new RegExp(`nestly:${kind}:`), `the ${kind} prefix must survive`);
  // A member code writes nothing, so it returns before the idempotency machinery.
  const submit = section("const submit=async value=>{", "const decodeSource=(source,width,height)=>{");
  assert.match(submit, /if\(payload\.kind==='member'\)\{/);
  assert.ok(submit.indexOf("payload.kind==='member'") < submit.indexOf('redemptionAttempt={fingerprint'),
    'the member branch must return before any idempotency key is minted');
});

test('W6I2 D2 the member QR is built against a named contract and shipped OFF', () => {
  /* Both server halves are unshipped. Naming an ungranted function in this bundle is refused on
     purpose by docs/design/ps0/writer-registry.json and the v21 authenticated-RPC allowlist, so the
     capability gate is a declared constant rather than an error branch around a call. */
  assert.match(code, /const MEMBER_CODE_CONTRACT_W6I2=Object\.freeze\(\{readerShipped:false,resolverShipped:false\}\);/);
  assert.doesNotMatch(code, /sb\.rpc\('customer_get_member_code_v310'/);
  assert.doesNotMatch(code, /sb\.rpc\('staff_resolve_member_code_v310'/);
  assert.doesNotMatch(code, /customerRpc\('customer_get_member_code_v310'/);
  // One reader shim, so the RPC name lands in exactly one edit when the migration arrives.
  assert.match(code, /async function memberCodeForWalletW6I2\(\)\{\s*\r?\n?\s*if\(!MEMBER_CODE_CONTRACT_W6I2\.readerShipped\)return '';/);
  assert.match(code, /status\.textContent=MEMBER_CODE_CONTRACT_W6I2\.resolverShipped/);
  assert.match(code, /Member codes need the latest Peekaa service update\./);
});

test('W6I2 D3 the member card is gated exactly like the W4b stack, and the slot is removed otherwise', () => {
  /* W4b's gate, verbatim: programmes_contract==='v310' with at least one programme row. A firm the
     spine cannot describe has no membership to show a code for, and the pre-v310 tab surface never
     carried this card — so an old server must render byte-identically to before. */
  assert.match(code, /if\(!MEMBER_CODE_CONTRACT_W6I2\.readerShipped\|\|!programmeStackV310\(programmeCapabilities\)\)\{\s*\r?\n?\s*slot\.remove\(\);return;/);
  assert.match(code, /const programmeStackV310=caps=>\s*\r?\n?\s*Array\.isArray\(caps\?\.programmes\)&&caps\.programmes\.length>0&&caps\?\.programmes_contract==='v310'/);
  // The slot W4b pre-shipped, and the copy it pre-translated into all four locales.
  assert.match(code, /id="customerMemberCodeSlotV310" class="customer-member-code-slot" hidden/);
  assert.match(html, /\.customer-member-code-slot\{/);
  assert.equal([...app.matchAll(/showMyCode:'/g)].length, 4, 'showMyCode ships in all four locales');
  assert.equal([...app.matchAll(/showMyCodeBody:'/g)].length, 4);
  assert.match(code, /function customerMemberCodeMarkupW6I2\(code\)\{/);
  assert.match(code, /esc\(ct\('showMyCode'\)\)/);
  /* The code is OPAQUE and per-business by contract. Printing a phone number or a client id would
     hand every counter an identifier that works at every other business too. */
  assert.match(code, /text:`nestly:member:\$\{code\}`/);
  assert.doesNotMatch(code, /customerMemberCodeMarkupW6I2\([^)]*phone/);
  // The QR is DRAWN; the readable fallback is what stays honest when the library cannot load.
  assert.match(code, /void loadQrLibrary\(\)\.then\(\(\)=>new QRCode\(\$\('customerMemberQrW6I2'\)/);
  assert.match(code, /data-member-code-value-w6i2/);
});

/* ================= housekeeping ================= */

test('W6I2 the whole surface is built from CSS the page already ships', () => {
  /* Nine checked-in browser fixtures inline app/index.html's stylesheet under a
     production-source-sha256 and carry CAPTURED CHROME MEASUREMENTS keyed to it. One new cosmetic
     rule would have forced a browser recapture of all nine for a border radius. Every class the
     switchboard uses already exists, and the 44px tap-target floor the wizard holds to is
     inherited rather than restated. */
  assert.match(html, /\.grow-setup-options-v301\{display:grid;grid-template-columns:repeat\(auto-fit,minmax\(200px,1fr\)\)/);
  assert.match(html, /\.grow-setup-option-v301\{/);
  assert.match(html, /\.pill\.on\{/);
  assert.match(html, /\.pill\.off\{/);
  assert.match(html, /\.grow-setup-step-v301\{[^}]*min-height:44px/);
  assert.match(html, /\.grow-setup-basisopt-v305\{[^}]*min-height:44px/);
  assert.doesNotMatch(html, /grow-setup-switch-w6i2|grow-setup-switchboard-w6i2|grow-setup-percent-w6i2/);
});

test('W6I2 every symbol the wave deleted is gone from the file, declaration and reference', () => {
  /* The top code risk of this section, stated in the W6 design contract: deleting a declaration
     while leaving a reference passes `node --check` and the entire suite, then crashes in
     production. Both halves, for every deleted symbol. */
  for (const gone of ['GROW_SETUP_MODELS_V303', 'GROW_SETUP_INTEGRITY_V305', 'GROW_SETUP_STEPS_V301',
    'GROW_SETUP_STEPS_TIERS_V303', 'GROW_SETUP_STEPS_TIERSONLY_V305', 'stepListV303', 'stepCountV303',
    'stepKindV303', 'stepNumberOrNullV305', 'stepNumberForV303', 'tierModelV303',
    'integrityLineHtmlV305', 'modelForFamily', 'growSetupModelForTileV303']) {
    assert.doesNotMatch(code, new RegExp(`(const|let|function)\\s+${gone}\\b`), `${gone} is declared`);
    assert.doesNotMatch(code, new RegExp(`${gone}\\s*\\(`), `${gone} is still called`);
    assert.doesNotMatch(code, new RegExp(`\\b${gone}\\b`), `${gone} is still referenced`);
  }
  // And the two state fields the exclusive pick owned.
  assert.doesNotMatch(code, /state\.pick/);
  assert.doesNotMatch(code, /state\.family/);
});

/* ================= E. BEHAVIOURAL PINS — the fix pass ==========================================
 *
 * Everything above this line is a SOURCE pin, and an adversarial verification of this wave proved
 * what that costs: five confirmed-broken defects passed all nineteen tests, because a regex that
 * matches the line it was written against still matches when the line's SURROUNDINGS make it
 * meaningless. The stored tier basis never reached the translator, the D3 basis gate compared a
 * value with itself, the referral guard read a cache the write above it had just refreshed, the
 * legacy publish routes collapsed a four-key spine into one key, and a points-earned ladder was
 * suggested for firms whose engine could never move it. A sixth — the four switches were WIRED to
 * `dataset.growSetupSwitchW6I2`, which the DOM spells `…W6i2`, so every toggle was inert — was
 * invisible to source pins by construction.
 *
 * So the wizard is RUN here. Its real source is evaluated with the page's collaborators stubbed and
 * a minimal DOM behind it; the assertions are about what the owner sees on the screen and which RPC
 * arguments leave the browser. Two of them go further and build their fixture row from the column
 * list the page's own select() asks for, so removing a column from that select makes the fixture
 * lose it and the test go red — the read gap and the assertion can never drift apart again.
 * Same technique as tests/customer-wallet/v310-programme-stack.test.mjs. */

const spineHelpersSrc = section('const PROGRAMME_SWITCHES_V314={', 'const PRODUCT_INTERACTION_EVENTS_V100=');
const wizardConstsSrc = section('const GROW_SETUP_SWITCHES_W6I2=[', 'async function growSetupComparisonV301(');
const escReal = value => String(value ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* The smallest DOM the wizard needs: it sets innerHTML, queries by [data-attribute] and by id, and
   hangs onclick/onchange handlers off what comes back. Element identity is cached per render so a
   handler bound during bind() is the same object a test later fires. dataset keys are derived with
   the REAL HTML rule (a hyphen followed by a lowercase letter is removed and the letter uppercased,
   and nothing else is touched) — that rule is what the sixth defect broke. */
const datasetKey = name => name.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
function makeDom() {
  let markup = '';
  const byId = new Map(), byAttr = new Map();
  const attrsOf = tag => {
    const out = {};
    for (const m of tag.matchAll(/([a-zA-Z0-9_:-]+)(?:="([^"]*)")?/g)) if (m[1]) out[m[1]] = m[2] ?? '';
    return out;
  };
  const tags = () => [...markup.matchAll(/<([a-z0-9]+)\b([^>]*)>/gi)].map(m => attrsOf(m[2]));
  const makeEl = attrs => {
    const dataset = {};
    Object.keys(attrs).forEach(k => { if (k.startsWith('data-')) dataset[datasetKey(k.slice(5))] = attrs[k] });
    const el = { attrs, dataset, value: attrs.value ?? '', checked: 'checked' in attrs,
      disabled: 'disabled' in attrs, textContent: '', onclick: null, onchange: null,
      addEventListener() {}, setAttribute() {}, removeAttribute() {}, focus() {},
      querySelector: () => null, querySelectorAll: () => [] };
    return el;
  };
  const host = {
    get innerHTML() { return markup },
    set innerHTML(value) { markup = value; byId.clear(); byAttr.clear() },
    querySelectorAll(selector) {
      const m = /^\[([a-z0-9-]+)(?:="([^"]*)")?\]$/.exec(selector);
      if (!m) return [];
      if (!byAttr.has(m[1])) byAttr.set(m[1], tags().filter(t => m[1] in t).map(makeEl));
      const all = byAttr.get(m[1]);
      return m[2] === undefined ? all : all.filter(el => el.attrs[m[1]] === m[2]);
    },
    querySelector(selector) { return host.querySelectorAll(selector)[0] || null }
  };
  const $ = id => {
    if (byId.has(id)) return byId.get(id);
    const tag = tags().find(t => t.id === id);
    if (!tag) return null;
    const el = makeEl(tag);
    byId.set(id, el);
    return el;
  };
  return { host, $, get markup() { return markup } };
}

const wizardFactory = new Function('S', 'sb', 'esc', 'CUI', '$', 'toast', 'ownerErrorText',
  'localizeWorkspaceSubtreeV97', 'expiryModeRequiresDays', 'growSetupComparisonV301',
  'pendingGrowSetupModelV303', 'pendingGrowSetupRewardV303', `
  ${spineHelpersSrc}
  ${wizardConstsSrc}
  ${section('async function growSetupWizardV301(', 'function growPublishFieldRowsV170(')}
  return {growSetupWizardV301,applyPublishedProgrammeSwitchesV314,programmeSwitchesForPublishV314};`);

/* The go-live change list's own row builder, evaluated with the real label tables. */
const publishRows = new Function('studioMoney', `
  ${section('const GROW_PUBLISH_MODEL_LABEL_V170=', 'const GROW_PUBLISH_TIER_BASIS_LABEL_V175=')}
  ${section('const GROW_PUBLISH_TIER_BASIS_LABEL_V175=', '\n/*')}
  ${section('function growPublishFieldRowsV170(', '/* ============================ Program Studio page')}
  return growPublishFieldRowsV170;`)(cents => `$${(Number(cents || 0) / 100).toFixed(2)}`);

const SPINE_KINDS = ['points', 'tiers', 'stamps', 'referral'];
const spineRows = on => SPINE_KINDS.map(kind => ({ kind, active: on.includes(kind) }));

/* THE COLUMN-COUPLED FIXTURE. The published programme row a screen receives is built from the exact
   column list that screen's own select() asks the database for — so a column the select does not
   name is a key the fixture does not have, exactly as in production. */
const selectColumns = (haystack, label) => {
  const m = /sb\.from\('loyalty_programs'\)\.select\('([^']+)'\)/.exec(haystack);
  assert.ok(m, `no loyalty_programs select found in ${label}`);
  return m[1].split(',').map(column => column.trim());
};
const overviewColumns = selectColumns(section('async function growOverviewSnapshot(', 'const draftHeaderV268='),
  'growOverviewSnapshot');
const comparisonColumns = selectColumns(section('async function growSetupComparisonV301(', 'const pseudoSnapshot='),
  'growSetupComparisonV301');
const STORED_PROGRAM = { id: 'lp-1', active: true, loyalty_model: 'points_tiers',
  current_config_version_id: 'v1', earn_points_per_dollar: 1, redeem_points: 800,
  reward_credit_cents: 800, stamp_target: 10, stamp_per_cents: null, tier_basis: 'visits',
  expiry_mode: 'none', expiry_days: null };
const rowAsSelected = (columns, stored = STORED_PROGRAM) =>
  Object.fromEntries(columns.filter(column => column in stored).map(column => [column, stored[column]]));

function mountWizard({ spine = null, industry = 'salon', snapshot = {}, liveTiers = null,
  startStep = 1, rpcHandlers = {}, pointsMode = 'redeem' } = {}) {
  const dom = makeDom(), rpc = [];
  const S = { biz: { id: 'biz-1', currency: 'SGD', industry, points_mode: pointsMode },
    programmes: spine, programmesBusinessId: spine ? 'biz-1' : null, myRole: 'owner' };
  const defaults = {
    create_loyalty_config_draft: async () => ({ data: { version_id: 'draft-1', snapshot_hash: 'h1' }, error: null }),
    save_loyalty_config_draft: async () => ({ data: { snapshot_hash: 'h2' }, error: null }),
    save_loyalty_tier_draft_v143: async () => ({ data: { snapshot_hash: 'h3' }, error: null }),
    preview_publish_impact: async () => ({ data: { rules: [], requires_confirmation: false }, error: null }),
    publish_loyalty_config: async () => ({ data: {}, error: null }),
    save_referral_program: async () => ({ data: {}, error: null }),
    get_loyalty_reward_draft: async () => ({ data: { program: null, rewards: [], tiers: [] }, error: null }),
    set_programmes_v314: async args => ({ data: { programmes: Object.entries(args.p_switches)
      .map(([kind, active]) => ({ kind, active })) }, error: null })
  };
  const sb = { rpc: async (name, args) => { rpc.push({ name, args });
      return (rpcHandlers[name] || defaults[name] || (async () => ({ data: {}, error: null })))(args) },
    from: () => ({ select: () => ({ eq: () => ({ limit: async () => ({ data: [], error: null }) }) }) }) };
  const api = wizardFactory(S, sb, escReal, { icon: () => '' }, dom.$, () => {},
    error => String(error?.message || error || ''), () => {},
    mode => mode === 'fixed' || mode === 'inactivity',
    async () => ({ error: null, lines: [], unreadable: [], draftActive: null }), null, null);
  const full = { currentVersion: 'v1', loyalty: null, rewards: [{ id: 'r1', customer_name: 'Free coffee',
    cost_points: 100, active: true, estimated_cost_cents: 300 }], draft: null, draftDetail: null,
    referral: null, ...snapshot };
  return { dom, S, sb, rpc, api,
    open: () => api.growSetupWizardV301({ host: dom.host, snapshot: full, isCurrent: () => true,
      startStep, liveTiers }),
    press: async id => { const el = dom.$(id); assert.ok(el, `no #${id} on screen`); await el.onclick() },
    click: async selector => { const el = dom.host.querySelector(selector);
      assert.ok(el, `no ${selector} on screen`); await el.onclick() },
    title: () => /<h3 class="grow-setup-title-v301">([^<]*)</.exec(dom.markup)?.[1] || '',
    rail: () => [...dom.markup.matchAll(/class="grow-setup-step-label-v301">([^<]*)</g)].map(m => m[1]),
    configWrites: () => rpc.filter(call => call.name === 'save_loyalty_config_draft').map(call => call.args.p_config),
    called: name => rpc.filter(call => call.name === name) };
}

/* ---------------- defect 1: the stored basis reaches the wizard ---------------- */

test('W6I2 E1 a firm on a stored VISITS ladder opens on Visits and publishes Visits (defect 1)', async () => {
  /* The forbidden case in the owner amendment's own words. The wizard's `live` is the row
     growOverviewSnapshot selects, and after every publish there is no open draft, so that row IS
     the only source of the stored basis. With tier_basis absent from the select the wizard saw
     `undefined`, decided the ladder was NEW, pre-picked "Points earned · Suggested", and the first
     Next wrote tier_basis='points_earned' over a live visits ladder — re-sorting every member with
     no warning and no tick. The fixture below carries exactly the columns the select asks for, so
     this test fails the moment tier_basis is dropped from it again. */
  assert.ok(overviewColumns.includes('tier_basis'),
    'growOverviewSnapshot must select tier_basis — the wizard cannot read a column it never asked for');
  const w = mountWizard({ spine: spineRows(['points', 'tiers']),
    snapshot: { loyalty: rowAsSelected(overviewColumns) },
    liveTiers: [{ id: 't1', name: 'Silver', threshold: 0, active: true },
      { id: 't2', name: 'Gold', threshold: 5, active: true }], startStep: 5 });
  await w.open();
  assert.equal(w.title(), 'Step 5 of 7 · Climbing');
  assert.match(w.dom.markup, /data-grow-setup-basis-v305="visits" [^>]*aria-checked="true"|aria-checked="true" data-grow-setup-basis-v305="visits"/,
    'the stored basis is the selected one');
  assert.doesNotMatch(w.dom.markup, /Suggested/,
    'a stored basis is a decision, never a suggestion');
  await w.press('growSetupNextV301');
  const written = w.configWrites().map(config => config.tier_basis).filter(Boolean);
  assert.deepEqual(written, ['visits'],
    `Next must write back the stored basis, not the suggestion (wrote ${JSON.stringify(written)})`);
});

test('W6I2 E1 the go-live change list does not invent a "not set" tier basis (defect 1)', () => {
  /* Same read gap, one screen over. growPublishFieldRowsV170 prints a row for every field whose
     live value differs from the draft's, so a live side with no tier_basis key printed
     "Tier level is earned by: not set → Points earned" for firms that had never changed anything —
     a change list that manufactures its own "before" is worse than no change list. */
  assert.ok(comparisonColumns.includes('tier_basis'), 'growSetupComparisonV301 must select tier_basis');
  const live = rowAsSelected(comparisonColumns);
  const unchanged = publishRows(live, { ...live, active: true });
  assert.deepEqual(unchanged.filter(row => row.label === 'Tier level is earned by'), [],
    'nothing changed, so the basis must not be listed at all');
  const rebased = publishRows(live, { ...live, tier_basis: 'points_earned' });
  assert.deepEqual(rebased.filter(row => row.label === 'Tier level is earned by'),
    [{ label: 'Tier level is earned by', before: 'Number of visits', after: 'Lifetime points earned' }],
    'a real re-basing names what customers are on today');
});

/* ---------------- defect 2: the D3 basis gate survives leaving and coming back ------------- */

test('W6I2 E2 a basis change parked in the draft still gates on re-entry (defect 2)', async () => {
  /* Session 1 changed the basis and pressed Next, which wrote it into the draft; session 2 reopens.
     Comparing the draft against ITSELF (initialTierBasisV305) makes the gate see no change, so the
     publish re-based every member with no movement block and no tick. The threshold half of D3 was
     always re-entry-safe because it compares the draft against the PUBLISHED ladder; this is the
     same comparison for the basis. */
  const w = mountWizard({ spine: spineRows(['points', 'tiers']),
    snapshot: { loyalty: { ...rowAsSelected(overviewColumns), tier_basis: 'visits' },
      draft: { id: 'draft-1', snapshot_hash: 'h0' },
      draftDetail: { program: { ...STORED_PROGRAM, tier_basis: 'points_earned' }, rewards: [], tiers: [] } },
    liveTiers: [{ id: 't1', name: 'Silver', threshold: 0, active: true },
      { id: 't2', name: 'Gold', threshold: 5, active: true }], startStep: 'review' });
  await w.open();
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.match(w.title(), /Go live/);
  assert.match(w.dom.markup, /data-grow-setup-tiermove-w6i2/, 'the movement block must render');
  assert.match(w.dom.markup, /Tier level is earned by: <s>Visits<\/s> → <b>Points earned<\/b>/,
    'and it names what customers are on TODAY as the "before"');
  assert.match(w.dom.markup, /id="growSetupNextV301" disabled/, 'Publish is refused until the tick is in');
  /* The disabled attribute is a hint, not a guard — the error block's Retry calls advance()
     directly. Firing the handler is exactly what that button does. */
  await w.press('growSetupNextV301');
  assert.deepEqual(w.called('publish_loyalty_config'), [],
    'the publish flow must re-check the gate, not trust the rendered attribute');
  assert.match(w.dom.markup, /Tick the box above to confirm members can move down a tier/);
});

test('W6I2 E2 the same wizard publishes once the D3 tick is in (defect 2, the other direction)', async () => {
  const w = mountWizard({ spine: spineRows(['points', 'tiers']),
    snapshot: { loyalty: { ...rowAsSelected(overviewColumns), tier_basis: 'visits' },
      draft: { id: 'draft-1', snapshot_hash: 'h0' },
      draftDetail: { program: { ...STORED_PROGRAM, tier_basis: 'points_earned' }, rewards: [], tiers: [] } },
    liveTiers: [{ id: 't1', name: 'Silver', threshold: 0, active: true }], startStep: 'review' });
  await w.open();
  await new Promise(resolve => setTimeout(resolve, 5));
  const tick = w.dom.$('growSetupTierAckW6I2');
  assert.ok(tick, 'the D3 checkbox is on the gate');
  tick.checked = true; tick.onchange();
  await w.press('growSetupNextV301');
  assert.equal(w.called('publish_loyalty_config').length, 1, 'an admitted movement publishes');
});

/* ---------------- defect 3: referral_programs stays in step with the switch ---------------- */

test('W6I2 E3 turning Referral ON writes referral_programs, default accepted (defect 3)', async () => {
  /* The engine's referral block reads referral_programs.enabled, not the spine (v311), so a spine
     row switched on with no row behind it is a programme that looks live and pays nothing. The
     guard that was supposed to prevent it read the spine AFTER set_programmes_v314 had refreshed
     the cache from its own reply, so "did it move?" compared the new value with itself. */
  const w = mountWizard({ spine: spineRows([]), industry: 'retail',
    snapshot: { loyalty: rowAsSelected(overviewColumns) } });
  await w.open();
  await w.click('[data-grow-setup-switch-w6i2="referral"]');
  assert.ok(w.rail().includes('Referral'), 'the toggle put the referral rail on screen');
  for (let guard = 0; guard < 8 && !/Go live/.test(w.title()); guard++) await w.press('growSetupNextV301');
  assert.match(w.title(), /Go live/);
  await w.press('growSetupNextV301');
  const [referral] = w.called('save_referral_program');
  assert.ok(referral, 'accepting the seeded default must still write the live referral row');
  assert.equal(referral.args.p_enabled, true);
  assert.equal(referral.args.p_reward_cents, 1000);
});

test('W6I2 E3 turning Referral OFF disables referral_programs, untouched inputs (defect 3)', async () => {
  /* The money direction. Left alone, referral_programs.enabled stayed true and a qualifying first
     visit kept minting referral credit on a firm the wizard had just promised earns nothing. */
  const w = mountWizard({ spine: spineRows(['points', 'referral']), industry: 'retail',
    snapshot: { loyalty: rowAsSelected(overviewColumns),
      referral: { id: 'ref-1', enabled: true, reward_cents: 1000, min_spend_cents: 0 } } });
  await w.open();
  await w.click('[data-grow-setup-switch-w6i2="referral"]');
  assert.ok(!w.rail().includes('Referral'), 'the referral rail went with the switch');
  for (let guard = 0; guard < 8 && !/Go live/.test(w.title()); guard++) await w.press('growSetupNextV301');
  await w.press('growSetupNextV301');
  const [referral] = w.called('save_referral_program');
  assert.ok(referral, 'switching a live referral programme off must reach referral_programs');
  assert.equal(referral.args.p_enabled, false);
});

test('W6I2 E3 a keep-it-paused publish disables referral too (defect 3)', async () => {
  const w = mountWizard({ spine: spineRows(['points', 'referral']), industry: 'retail',
    snapshot: { loyalty: rowAsSelected(overviewColumns),
      referral: { id: 'ref-1', enabled: true, reward_cents: 1000, min_spend_cents: 0 } },
    startStep: 'review' });
  await w.open();
  await new Promise(resolve => setTimeout(resolve, 5));
  const pause = w.dom.$('growSetupPauseV301');
  pause.checked = true; pause.onchange();
  await w.press('growSetupNextV301');
  const [referral] = w.called('save_referral_program');
  assert.ok(referral, '"customers earn nothing" has to reach the table the engine reads');
  assert.equal(referral.args.p_enabled, false);
  const [switches] = w.called('set_programmes_v314');
  assert.deepEqual(switches.args.p_switches, { points: false, tiers: false, stamps: false, referral: false });
});

test('W6I2 E3 the referral "before" is read from referral_programs, not from the spine (defect 3)', async () => {
  /* Re-verification proved the three pins above stay green if the captured "before" is taken from
     the SPINE again, because in every one of those fixtures the two agree. They can disagree — the
     spine row is the display truth and referral_programs.enabled is the money truth, and nothing
     but the wizard writes both — so the pin has to be a fixture where they differ.
     Here the spine says referral is OFF (so the switchboard paints it off and the owner changes
     nothing) while the live row still says enabled=true and the engine is still paying. Reading
     the spine sees false === false and writes nothing, leaving the payout running under a firm
     whose every surface says referral is off. Reading referral_programs sees true !== false and
     heals it. */
  const w = mountWizard({ spine: spineRows(['points']), industry: 'retail',
    snapshot: { loyalty: rowAsSelected(overviewColumns),
      referral: { id: 'ref-1', enabled: true, reward_cents: 1000, min_spend_cents: 0 } },
    startStep: 'review' });
  await w.open();
  await new Promise(resolve => setTimeout(resolve, 5));
  await w.press('growSetupNextV301');
  const [referral] = w.called('save_referral_program');
  assert.ok(referral, 'a live referral row under an off switch must be disabled at publish');
  assert.equal(referral.args.p_enabled, false);
});

/* ---------------- defect 4: a legacy publish never destroys a multi-programme state -------- */

test('W6I2 E4 a points+stamps firm keeps both when it publishes from a legacy route (defect 4)', async () => {
  /* Both non-wizard publish routes collapsed the spine into ONE legacy model key — stamps first,
     unconditionally — and the exclusive set behind that key switched points OFF. Earning stopped
     and points rewards were refused, under a green "published" toast. A publish republishes
     numbers; it is not a place to change which programmes run. */
  const w = mountWizard({ spine: spineRows(['points', 'stamps']) });
  await w.api.applyPublishedProgrammeSwitchesV314({ active: true, loyaltyModel: 'points_tiers' });
  const [call] = w.called('set_programmes_v314');
  assert.deepEqual(call.args.p_switches,
    { points: true, tiers: false, stamps: true },
    'the spine is re-asserted as it stands, not collapsed into one legacy key');
});

test('W6I2 E4 a referral-only firm is not handed a points programme by publishing (defect 4)', async () => {
  const w = mountWizard({ spine: spineRows(['referral']) });
  await w.api.applyPublishedProgrammeSwitchesV314({ active: true, loyaltyModel: 'points_tiers' });
  assert.deepEqual(w.called('set_programmes_v314')[0].args.p_switches,
    { points: false, tiers: false, stamps: false },
    'referral counts as "something is running", so the legacy tail never fires and no points '
    + 'programme is invented — and referral itself is left exactly as it was');
});

test('W6I2 E4 publishing PAUSED still switches everything off (defect 4 keeps the v314 rule)', async () => {
  const w = mountWizard({ spine: spineRows(['points', 'stamps']) });
  await w.api.applyPublishedProgrammeSwitchesV314({ active: false, loyaltyModel: 'points_tiers' });
  assert.deepEqual(w.called('set_programmes_v314')[0].args.p_switches,
    { points: false, tiers: false, stamps: false });
});

test('W6I2 E4 a legacy publish route never moves the REFERRAL switch (defect 4 containment)', async () => {
  /* The regression the first cut of this fix introduced, caught by re-verification. Widening these
     routes to all four keys made them the first non-wizard writer of the referral spine row — while
     neither route writes referral_programs.enabled, which is what app.on_sale_recorded actually
     gates the referral payout on. A live-referral firm publishing a PAUSED draft from the Grow
     review page would then read referral OFF on every surface and keep minting referral credit:
     defect 3's split, reopened one door over. A route that cannot keep the pair in step touches
     neither half. */
  const w = mountWizard({ spine: spineRows(['points', 'referral']),
    snapshot: { loyalty: rowAsSelected(overviewColumns),
      referral: { id: 'ref-1', enabled: true, reward_cents: 1000, min_spend_cents: 0 } } });
  await w.api.applyPublishedProgrammeSwitchesV314({ active: false, loyaltyModel: 'points_tiers' });
  const [call] = w.called('set_programmes_v314');
  assert.ok(!('referral' in call.args.p_switches),
    'a paused legacy publish must not switch referral off behind referral_programs.enabled');
  assert.deepEqual(call.args.p_switches, { points: false, tiers: false, stamps: false });
  assert.equal(w.called('save_referral_program').length, 0,
    'and it must not pretend to write the referral row either');
});

test('W6I2 E4 a firm with nothing running still goes live from a legacy route (v314 increment 1)', async () => {
  /* The regression the fix must NOT cause. A spine with every row off is also what a brand-new
     tenant reads, and increment 1 exists because such a firm published from the Grow review page
     and went live with all four rows false: the page said Live and the next sale earned nothing.
     Nothing-on is not an answer, so that case keeps the legacy selection. */
  const w = mountWizard({ spine: spineRows([]), pointsMode: 'both' });
  await w.api.applyPublishedProgrammeSwitchesV314({ active: true, loyaltyModel: 'points_tiers' });
  assert.deepEqual(w.called('set_programmes_v314')[0].args.p_switches, { points: true, tiers: true });
});

/* ---------------- defect 5: a ladder the engine can never move is refused ------------------ */

test('W6I2 E5 a points-earned ladder with Points & gifts off is refused, not published (defect 5)', async () => {
  /* app.loyalty_tier_for measures a points-earned ladder from earn rows scoped to the POINTS
     programme, and those rows are written only for an ACTIVE points spine row — so tiers-on /
     points-off / points-earned is a ladder frozen at its base rung forever. The plan's silent
     accrual has no physical representation (business_programmes carries kind and active and
     nothing else), so the honest fix is a real, visible dependency. */
  const w = mountWizard({ spine: spineRows(['tiers']), industry: 'fitness',
    snapshot: { loyalty: { ...rowAsSelected(overviewColumns), tier_basis: 'points_earned' } },
    liveTiers: [{ id: 't1', name: 'Silver', threshold: 0, active: true }], startStep: 2 });
  await w.open();
  assert.match(w.title(), /Climbing/);
  assert.match(w.dom.markup, /data-grow-setup-climbneedspoints-w6i2/, 'the requirement is on the screen');
  assert.doesNotMatch(w.dom.markup, /id="growSetupEarnV301"/,
    'and no earn rate is collected for an engine that would never apply it');
  await w.press('growSetupNextV301');
  assert.deepEqual(w.configWrites(), [], 'Next refuses rather than saving a ladder that cannot move');
  assert.match(w.dom.markup, /Points &amp; gifts has to be running/);
});

test('W6I2 E5 one tap turns Points & gifts on and keeps the owner on Climbing (defect 5)', async () => {
  const w = mountWizard({ spine: spineRows(['tiers']), industry: 'fitness',
    snapshot: { loyalty: { ...rowAsSelected(overviewColumns), tier_basis: 'points_earned' } },
    liveTiers: [{ id: 't1', name: 'Silver', threshold: 0, active: true }], startStep: 2 });
  await w.open();
  await w.press('growSetupTurnOnPointsW6I2');
  assert.match(w.title(), /Climbing/, 'the owner stays on the screen they were reading');
  assert.deepEqual(w.rail(), ['Programmes', 'Earning', 'Gifts', 'Expiry', 'Climbing', 'Tiers', 'Go live']);
  assert.doesNotMatch(w.dom.markup, /data-grow-setup-climbneedspoints-w6i2/);
  await w.press('growSetupNextV301');
  assert.deepEqual(w.configWrites().map(config => config.tier_basis), ['points_earned'],
    'and the basis it was already on is what gets written');
});

test('W6I2 E5 Visits stays a first-class one-tap answer (owner amendment)', async () => {
  const w = mountWizard({ spine: spineRows(['tiers']), industry: 'fitness',
    snapshot: { loyalty: { ...rowAsSelected(overviewColumns), tier_basis: 'points_earned' } },
    liveTiers: [{ id: 't1', name: 'Silver', threshold: 0, active: true }], startStep: 2 });
  await w.open();
  await w.click('[data-grow-setup-basis-v305="visits"]');
  assert.doesNotMatch(w.dom.markup, /data-grow-setup-climbneedspoints-w6i2/);
  assert.ok(!w.rail().includes('Earning'), 'a visits ladder needs no points programme at all');
  await w.press('growSetupNextV301');
  assert.deepEqual(w.configWrites().map(config => config.tier_basis), ['visits']);
});

test('W6I2 E5 the publish gate refuses a stalled ladder in words (defect 5)', async () => {
  const w = mountWizard({ spine: spineRows(['tiers']), industry: 'fitness',
    snapshot: { loyalty: { ...rowAsSelected(overviewColumns), tier_basis: 'points_earned' } },
    liveTiers: [{ id: 't1', name: 'Silver', threshold: 0, active: true }], startStep: 'review' });
  await w.open();
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.match(w.dom.markup, /data-grow-setup-ladderstalled-w6i2/);
  await w.press('growSetupNextV301');
  assert.deepEqual(w.called('publish_loyalty_config'), []);
});

/* ---------------- the wiring the source pins could not see ---------------- */

test('W6I2 E6 the four switches actually toggle, and only the one that was pressed', async () => {
  /* The sixth defect, and the one a source pin can never catch: the handler read
     `dataset.growSetupSwitchW6I2` while the DOM spells that attribute `growSetupSwitchW6i2`, so
     every press hit `if(!PROGRAMME_KINDS_W6I2.includes(undefined))return` and all four toggles were
     dead. The rail is the observable: turning a programme on puts its screens on screen. */
  const w = mountWizard({ spine: spineRows(['points']), industry: 'retail',
    snapshot: { loyalty: rowAsSelected(overviewColumns) } });
  await w.open();
  assert.deepEqual(w.rail(), ['Programmes', 'Earning', 'Gifts', 'Expiry', 'Go live']);
  await w.click('[data-grow-setup-switch-w6i2="stamps"]');
  assert.deepEqual(w.rail(),
    ['Programmes', 'Stamps', 'Stamp gift', 'Earning', 'Gifts', 'Expiry', 'Go live'],
    'stamps joined and points stayed exactly as it was');
  await w.click('[data-grow-setup-switch-w6i2="points"]');
  assert.deepEqual(w.rail(), ['Programmes', 'Stamps', 'Stamp gift', 'Go live'],
    'and turning one off takes its screens with it, leaving the other alone');
});

test('W6I2 E6 the one-tap expiry chips actually set the mode', async () => {
  const w = mountWizard({ spine: spineRows(['points']), industry: 'retail',
    snapshot: { loyalty: rowAsSelected(overviewColumns) }, startStep: 4 });
  await w.open();
  assert.match(w.title(), /Expiry/);
  await w.click('[data-grow-setup-expiry-w6i2="year"]');
  await w.press('growSetupNextV301');
  const [written] = w.configWrites();
  assert.equal(written.expiry_mode, 'fixed');
  assert.equal(written.expiry_days, 365);
});

test('W6I2 E7 an absent tier_movements key prints the honest sentence, never a zero', async () => {
  /* C3's call-site coupling, which the source pin could not reach: the honest sentence is only
     honest if `counts===null` actually reaches it. The server key does not exist yet, so this is
     the sentence every workspace sees today. */
  const w = mountWizard({ spine: spineRows(['points', 'tiers']),
    snapshot: { loyalty: { ...rowAsSelected(overviewColumns), tier_basis: 'visits' },
      draft: { id: 'draft-1', snapshot_hash: 'h0' },
      draftDetail: { program: { ...STORED_PROGRAM, tier_basis: 'points_earned' }, rewards: [], tiers: [] } },
    liveTiers: [{ id: 't1', name: 'Silver', threshold: 0, active: true }], startStep: 'review',
    rpcHandlers: { preview_publish_impact: async () => ({ data: { rules: [], requires_confirmation: false }, error: null }) } });
  await w.open();
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.match(w.dom.markup, /How many members move is not counted yet on this workspace/);
  assert.doesNotMatch(w.dom.markup, /0 members would move down/);
});

test('W6I2 E8 editing the ladder after ticking D3 takes the tick back', async () => {
  /* The tick admits a SPECIFIC set of moves. An owner who ticked for "Gold 5 → 50", went back and
     raised another rung, returned to a gate that listed the bigger change with the admission still
     in — earned for a lesser one. Only a real tier write clears it, so an untouched round trip does
     not cost the owner a tick they already gave. */
  const w = mountWizard({ spine: spineRows(['points', 'tiers']),
    snapshot: { loyalty: { ...rowAsSelected(overviewColumns), tier_basis: 'visits' },
      draft: { id: 'draft-1', snapshot_hash: 'h0' },
      draftDetail: { program: { ...STORED_PROGRAM, tier_basis: 'visits' }, rewards: [],
        tiers: [{ tier_id: 't1', name: 'Silver', threshold: 0, active: true },
          { tier_id: 't2', name: 'Gold', threshold: 50, active: true }] } },
    liveTiers: [{ id: 't1', name: 'Silver', threshold: 0, active: true },
      { id: 't2', name: 'Gold', threshold: 5, active: true }], startStep: 'review' });
  await w.open();
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.match(w.dom.markup, /data-grow-setup-tiermove-w6i2/, 'a raised threshold gates');
  const tick = w.dom.$('growSetupTierAckW6I2');
  tick.checked = true; tick.onchange();
  assert.equal(w.dom.$('growSetupNextV301').disabled, false, 'the tick releases the button');
  await w.press('growSetupBackV301');
  assert.match(w.title(), /Tiers/);
  await w.click('[data-grow-setup-tier-edit-v303="t2"]');
  await w.press('growSetupNextV301');
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.match(w.title(), /Go live/);
  assert.equal(w.called('save_loyalty_tier_draft_v143').length, 1, 'the ladder really was written');
  assert.doesNotMatch(w.dom.markup, /id="growSetupTierAckW6I2"[^>]*checked/, 'the tick is back to unticked');
  assert.match(w.dom.markup, /id="growSetupNextV301" disabled/, 'and it has to be given again');
});
