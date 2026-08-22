/* V322 — the owner rulings of 2026-08-14. BEHAVIOURAL pins, not source regexes.
 *
 * The W6I2 wave is the reason this file is written the way it is: nineteen source-level pins were
 * green through five confirmed-broken defects and an entirely inert switchboard, because a regex
 * that matches the line it was written against still matches when the line's SURROUNDINGS make it
 * meaningless. So every rule below is EVALUATED — the real function is lifted out of app/app.js,
 * given real collaborators, and asked what it does.
 *
 * What each section guards:
 *   R6  the wizard's Programmes step is SCOPE. Publishing must never send `false` for a programme
 *       the owner merely did not tick. This was a LIVE DEFECT: unticking Tier switched a live tier
 *       programme off for every customer.
 *   R2/R3 stamps is exclusive, referral is orthogonal, and the exclusivity is stated before it
 *       happens rather than applied silently.
 *   R1/R4 referral pays POINTS. No surface may still say credit, and no writer may still send cents.
 *   R5  the stamp card is a quest with an unbounded milestone list, and the one thing it cannot
 *       promise is stated on the screen instead of implied.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const stripComments = source => source
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/^\s*\/\/.*$/gm, '');
const code = stripComments(app);

/* Lift a top-level declaration out of the file by name, from `const NAME`/`function NAME` up to
   (but not including) the next top-level declaration. Evaluating the REAL bytes is the whole
   point — a copy in this file would be a second implementation that cannot go stale together. */
const topLevel = (name, endMarker) => {
  const start = app.search(new RegExp(`^(?:const|function) ${name}\\b`, 'm'));
  assert.ok(start >= 0, `missing top-level declaration: ${name}`);
  const end = app.indexOf(endMarker, start);
  assert.ok(end > start, `missing end marker for ${name}: ${endMarker}`);
  return app.slice(start, end);
};
/* A closure that lives INSIDE growPage. Sliced by its own head and an explicit end marker, then
   evaluated with its collaborators passed in as parameters — which is also a check that the
   collaborator list is honest, because a missing one is a ReferenceError at call time. */
const closure = (head, endMarker) => {
  const start = app.indexOf(head);
  assert.ok(start >= 0, `missing closure: ${head}`);
  const end = app.indexOf(endMarker, start);
  assert.ok(end > start, `missing end marker for ${head}: ${endMarker}`);
  return app.slice(start, end);
};

const esc = value => String(value ?? '').replace(/[&<>"]/g, ch =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]));

/* ---------- the module-scope rules, evaluated ---------- */
const rulesSrc =
  topLevel('PROGRAMME_KINDS_W6I2', 'const PROGRAMME_PUBLISH_KINDS_W6I2') +
  topLevel('PROGRAMME_ACCRUAL_EXCLUSIVE_V322', 'function growPointsWordV322') +
  topLevel('growPointsWordV322', 'function programmeScopeSwitchesV322') +
  topLevel('programmeScopeSwitchesV322', 'function rememberProgrammeSpineV314');
const rules = new Function(
  `${rulesSrc}\nreturn {programmeScopeSwitchesV322,programmeExclusionsV322,growPointsWordV322,PROGRAMME_KINDS_W6I2};`
)();

/* =================================================================================================
 * R6 — SCOPE, NOT ON/OFF
 * ============================================================================================== */

test('V322 R6 a programme the owner did not tick is ABSENT from the switch payload, never false', () => {
  /* THE LIVE DEFECT. The wizard sent `{...state.switches}` — all four kinds, every time — so an
     owner who opened it to fix a gift, unticked Tier because they did not want to walk two tier
     screens, and pressed through to Publish had their LIVE tier programme switched off for every
     customer, silently. `public.set_programmes_v314` leaves an unnamed kind exactly as it found it,
     so ABSENCE is the mechanism by which unselecting stops meaning off. A `false` here would put
     the defect straight back. */
  const payload = rules.programmeScopeSwitchesV322(
    { points: true, tiers: false, stamps: false, referral: false });
  assert.deepEqual(payload, { points: true, stamps: false },
    'only the ticked kind, plus the exclusivity the owner confirmed');
  assert.ok(!Object.prototype.hasOwnProperty.call(payload, 'tiers'),
    'tiers was not ticked, so it must not appear in the payload at all');
  assert.ok(!Object.prototype.hasOwnProperty.call(payload, 'referral'),
    'referral was not ticked, so it must not appear in the payload at all');
});

test('V322 R6 a referral-only run touches nothing but referral', () => {
  /* The narrowest possible scope. Every accruing programme must be left exactly as it was — this
     is the shape an owner opening the wizard from the Referrals card produces. */
  assert.deepEqual(
    rules.programmeScopeSwitchesV322({ points: false, tiers: false, stamps: false, referral: true }),
    { referral: true },
    'referral is orthogonal: it neither excludes nor is excluded');
});

test('V322 R6 keep-it-paused still turns the SELECTED set off, and still only the selected set', () => {
  /* PAUSED = the spine row is off, the rule v314 wrote down, and R6 does not change it: a
     programme the owner IS setting up and chose to publish paused legitimately goes off. What it
     must still not do is reach a programme they never selected. */
  const payload = rules.programmeScopeSwitchesV322(
    { points: true, tiers: true, stamps: false, referral: false }, { paused: true });
  assert.deepEqual(payload, { points: false, tiers: false },
    'both selected kinds go off; stamps is not cleared because nothing is being turned on');
  assert.ok(!Object.prototype.hasOwnProperty.call(payload, 'referral'),
    'a paused publish still must not switch an unselected programme');
});

test('V322 R6 an empty scope writes nothing at all', () => {
  assert.equal(
    rules.programmeScopeSwitchesV322({ points: false, tiers: false, stamps: false, referral: false }),
    null,
    'nothing ticked must produce no call, not a call that switches four things off');
});

test('V322 R6 the wizard publish sends the SCOPE, and the referral write is scoped with it', () => {
  /* Both halves of the same ruling, read off the real call site. The spine payload comes from
     programmeScopeSwitchesV322 (never `{...state.switches}`), and the companion
     referral_programs write — which is the column the ENGINE gates the payout on, not the spine —
     is skipped entirely when referral was not part of this run. */
  const apply = closure('async function applyProgrammeSwitchesV314(fromRetry){', 'const programRowV305=');
  assert.match(apply,
    /writeProgrammeSwitchesV314\(S\.biz\.id,\s*programmeScopeSwitchesV322\(state\.switches,\{paused:state\.keepPaused===true\}\)/);
  assert.doesNotMatch(stripComments(apply), /\{\.\.\.state\.switches\}/,
    'the all-four-keys payload is the defect itself and must not survive anywhere in this function');
  assert.match(apply, /if\(state\.switches\.referral!==true\)\{[^}]*return true\}/,
    'a run that never went near referral must leave referral_programs alone');
});

/* =================================================================================================
 * R2 / R3 — STAMPS IS EXCLUSIVE, REFERRAL IS NOT
 * ============================================================================================== */

test('V322 R2 turning the stamp card on clears points and tiers, in the same payload', () => {
  /* One call, not two. A two-step switch (stamps on, then points off) passes briefly through the
     shape the server now refuses, and it is also the path that strands a points pot — the residual
     V313-V314 §7.1 named. */
  assert.deepEqual(
    rules.programmeScopeSwitchesV322({ points: false, tiers: false, stamps: true, referral: false }),
    { stamps: true, points: false, tiers: false });
});

test('V322 R2 turning points or tiers on clears the stamp card', () => {
  assert.deepEqual(
    rules.programmeScopeSwitchesV322({ points: false, tiers: true, stamps: false, referral: false }),
    { tiers: true, stamps: false },
    'a tier ladder is on the points side of the exclusivity');
  assert.deepEqual(
    rules.programmeScopeSwitchesV322({ points: true, tiers: true, stamps: false, referral: true }),
    { points: true, tiers: true, referral: true, stamps: false },
    'points + tier + referral is a legal shape and referral rides along untouched');
});

test('V322 R2/R4 referral excludes nothing and is excluded by nothing', () => {
  assert.deepEqual(rules.programmeExclusionsV322('referral'), [],
    'referral must never turn a programme off');
  for (const kind of ['points', 'tiers', 'stamps']) {
    assert.ok(!rules.programmeExclusionsV322(kind).includes('referral'),
      `${kind} must never turn referral off`);
  }
  assert.deepEqual(
    rules.programmeScopeSwitchesV322({ stamps: true, referral: true }),
    { stamps: true, referral: true, points: false, tiers: false },
    'referral runs beside the stamp card — that is what universal means');
});

test('V322 R2 the wizard ARMS a confirmation before it clears the other side', () => {
  /* "picking Stamps clears points/tier and says so BEFORE it does". The first press must change
     nothing; it must set the pending kind and re-render. A handler that flipped and then explained
     would be the same class of defect R6 is fixing on the other axis. */
  const handler = closure("host.querySelectorAll('[data-grow-setup-switch-w6i2]')", 'host.querySelectorAll(\'[data-grow-setup-exclusive-confirm-w6i2]\')');
  assert.match(handler,
    /if\(state\.switches\[kind\]!==true&&exclusiveConflictsV322\(kind\)\.length\)\{\s*state\.pendingExclusiveV322=kind;return render\(\)/,
    'the first press on an excluding toggle arms the notice and returns without flipping');
  /* The dataset key rule that made every W6I2 toggle inert in a real browser: `data-…-w6i2`
     reaches the dataset as `…W6i2`, lowercase i. Both new handlers must obey it. */
  assert.match(code, /button\.dataset\.growSetupExclusiveConfirmW6i2/);
  assert.doesNotMatch(code, /dataset\.growSetupExclusiveConfirmW6I2/);
});

/* =================================================================================================
 * R1 / R4 — REFERRAL PAYS POINTS
 * ============================================================================================== */

test('V322 R1 no referral surface still writes or reads a money amount', () => {
  /* The owner's words: "why referral is a stored credits? please remove it as i already said no
     more store credits". reward_cents is FROZEN by v322 — kept as the historical record, read by
     nothing. A single surviving reader would put a money number back on a customer's screen. */
  assert.doesNotMatch(code, /p_reward_cents:/,
    'no client call may still send the referral payout in cents');
  assert.doesNotMatch(code, /sb\.rpc\('save_referral_program'/,
    'the pre-v322 money writer stays deployed for the CDN window but must have no call site');
  assert.doesNotMatch(code, /referral_programs'\)\.select\('[^']*reward_cents/,
    'no referral read may still ask for the frozen money column');
  for (const reader of ['referralProgrammeV294.reward_cents', 'snapshot.referral.reward_cents',
    'r.reward_cents', 'card?.reward_cents']) {
    assert.ok(!code.includes(reader), `a surface still renders ${reader}`);
  }
});

test('V322 R1 the points writer is the one the bundle calls, with an integer count', () => {
  /* nestly_v429 (B3): v425 gave the referral reward an explicit TYPE, which v322's four-argument signature cannot carry, so every call site moved to save_referral_program_v421 and none of them calls v322 any more. */
  assert.doesNotMatch(code, /sb\.rpc\('save_referral_program_v322'/);
  assert.match(code, /sb\.rpc\('save_referral_program_v421',\{p_business:S\.biz\.id,/);
  /* Points are whole. A ×100 anywhere on this path is the dollars round trip coming back. */
  const wizardWrite = code.match(/sb\.rpc\('save_referral_program_v421',\{p_business:S\.biz\.id,[\s\S]{0,700}?\}\)/g) || [];
  assert.ok(wizardWrite.length >= 2, 'the wizard and the Referrals page both write points');
  for (const call of wizardWrite) {
    assert.match(call, /p_reward_points:/);
    assert.doesNotMatch(call, /p_reward_points:[^,]*\*\s*100/,
      'the reward is a count of points, never cents');
  }
});

test('V322 R1 the points phrase is a named function, and it is singular-correct', () => {
  /* Interpolated runtime copy belongs in a named function (the v97 rule) so the localizer and this
     pin can both see it in one place. "1 points" is the tell that nobody looked. */
  assert.equal(rules.growPointsWordV322(1), '1 point');
  assert.equal(rules.growPointsWordV322(0), '0 points');
  assert.equal(rules.growPointsWordV322(400), '400 points');
  assert.equal(rules.growPointsWordV322(-5), '0 points', 'a negative payout is not a thing');
  assert.equal(rules.growPointsWordV322('12.6'), '13 points', 'points are whole');
});

test('V322 R1 the wizard referral screen asks for points and shows a points example', () => {
  const step = closure('const referralStepHtmlW6I2=()=>', 'const referralExampleTextW6I2=');
  assert.match(step, /Points for the customer who referred/);
  assert.match(step, /inputmode="numeric"/, 'a points count is not a decimal amount');
  assert.doesNotMatch(step, /Store credit/);
  assert.doesNotMatch(stripComments(step), /toFixed\(2\)[^<]*<\/div>\s*<div class="full"><label for="growSetupReferralMinW6I2"/,
    'the reward field must not still be formatted as money');
  const example = closure('const referralExampleTextW6I2=()=>', 'const tierBasisV303=');
  assert.match(example, /growPointsWordV322\(state\.referralReward\)/);
  assert.doesNotMatch(example, /credit to the referrer/);
});

/* =================================================================================================
 * R5 — THE STAMP CARD IS A QUEST
 * ============================================================================================== */

test('V322 R5 the milestone list renders every milestone, in stamp order, with no fixed slots', () => {
  /* "now is 3 sets in 1. but if bosses want to extend to 12 stamp = xx rewards and more = able to
     do it customisable". The list is rendered from the REAL function against a real ladder, in the
     wrong order on purpose, and the rendered order is what is asserted — a source pin could not
     tell a sorted list from an unsorted one. */
  const src = closure('const stampMilestonesV322=()=>', 'const stepThreeHtml=()=>');
  const rewards = [
    { id: 'r12', name: 'Bottle keep', points: 12, active: true },
    { id: 'r3', name: 'Free drink', points: 3, active: true },
    { id: 'r20', name: 'Spa hour', points: 20, active: true },
    { id: 'r5', name: 'Free snack', points: 5, active: true }
  ];
  const api = new Function('esc', 'unitWord', 'state', 'activeRewardsV304', 'rewardRowPointsTextV304',
    'rowMarkTextV304', 'rewardFormHtml',
    `${src}\nreturn {stampMilestonesHtmlV322,stampTargetFromMilestonesV322,stampMilestonesV322};`
  )(esc,
    (value, plural) => `${value} ${Number(value) === 1 ? 'stamp' : plural}`,
    { rewards },
    () => rewards.filter(r => r.active !== false),
    points => ` · ${points} stamps`,
    () => '',
    () => '<form data-form></form>');

  const markup = api.stampMilestonesHtmlV322();
  const order = [...markup.matchAll(/data-grow-setup-milestone-v322="(\d+)"/g)].map(m => Number(m[1]));
  assert.deepEqual(order, [3, 5, 12, 20],
    'a quest is ordered by its stamp counts, and there is no cap at three');
  assert.match(markup, /data-grow-setup-milestones-v322="4"/);
  assert.equal(api.stampTargetFromMilestonesV322(), 20);
  assert.match(markup, /data-grow-setup-stamplength-v322="20"/,
    'the card length is DERIVED from the last milestone, never typed beside it');
  assert.doesNotMatch(markup, /id="growSetupStampTargetV301"/,
    'the typed card-length field is what let a firm hold an 8-stamp card and a 12-stamp prize');
});

test('V322 R5 the screen states what claiming a milestone actually does today', () => {
  /* v323 RE-POINTED THIS PIN RATHER THAN DELETING IT, which is what the v322 note asked for. The
     sentence this guarded ("Claiming a milestone spends those stamps…") was true only while the
     claim drained points_batches FEFO. v323 closed exactly that gap, so the sentence became a lie
     and had to go with the defect. The pin stays, aimed at the sentence that is now true, because
     a screen that says nothing about what a claim costs is the state this rule exists to prevent. */
  const src = closure('const stampMilestonesHtmlV322=()=>', 'const stepThreeHtml=()=>');
  assert.match(src, /data-grow-setup-stampspend-v322/);
  assert.match(src, /Claiming a milestone does not spend the stamps/);
  assert.doesNotMatch(src, /Claiming a milestone spends those stamps/);
  assert.doesNotMatch(src, /is not built yet/);
  assert.doesNotMatch(src, /A full card wins a gift/);
});

test('V322 R5 the stamps rail names the milestone screen for what it is', () => {
  const rail = closure('const GROW_SETUP_RAIL_W6I2=[', 'const GROW_SETUP_SECTOR_DEFAULTS_W6I2');
  assert.match(rail, /\['stampGift','Milestones'\]/);
  /* Against the comment-stripped slice: the rationale ABOVE the array names the label it replaced,
     on purpose, which is how a later reader learns why it is gone. */
  assert.doesNotMatch(stripComments(rail), /Stamp gift/);
});

/* =================================================================================================
 * THE SEPARATE ON/OFF CONTROL (R6's "seperate button")
 * ============================================================================================== */

const mountSwitchPanel = ({ spine, pending = '', error = '', canSetupGrow = true,
  canRewards = true, referral = { reward_points: 200 } } = {}) => {
  const src = closure('const growProgrammeSwitchKindsV322=[', 'const growOngoingTopicsV244=');
  const rows = spine === null ? null
    : ['points', 'tiers', 'stamps', 'referral'].map(kind => ({ kind, active: spine.includes(kind) }));
  return new Function('esc', 'canRewards', 'canSetupGrow', 'snapshot',
    'growSwitchPendingV322', 'growSwitchErrorV322', 'programmeSpineRowsV314',
    'programmeSpineOnV314', 'programmeExclusionsV322',
    `${src}\nreturn growProgrammeSwitchPanelV322();`
  )(esc, canRewards, canSetupGrow, { referral }, pending, error,
    () => rows,
    kind => (rows ? rows.some(row => row.kind === kind && row.active) : null),
    rules.programmeExclusionsV322);
};

/* V334 (owner markup, 2026-08-15 photo 2: "remove all these"): the whole Live-for-customers
   on/off card is struck out of the Rewards Programme page. growProgrammeSwitchPanelV322 now
   returns '' unconditionally — the six tests this block used to hold (reading the spine state,
   the unreadable-spine fallback, the off/on confirmation copy, stamp exclusivity wording, the
   zero-reward referral warning, and the non-owner read-only view) all asserted markup that no
   longer renders. Replaced with one test asserting the removal, so a future re-introduction of
   this panel is a deliberate, reviewed decision rather than a silent regression. */
test('V334 the Live-for-customers on/off panel is removed from the Rewards Programme page', () => {
  const markup = mountSwitchPanel({ spine: ['points', 'referral'] });
  assert.equal(markup, '', 'the panel was struck out by the owner and must render nothing');
});

/* =================================================================================================
 * V324 — opening or cancelling the confirmation is a `hidden` toggle, not a re-render
 * ============================================================================================== */

test('V324 the confirm block ships in the DOM for every row, hidden unless it is the pending one', () => {
  /* Was `${pending?'<li … data-grow-switchconfirm-v322=...>…</li>':''}` — present only when
     pending, so opening it had no path but a full growPage() re-render. Now it is unconditional
     markup with a conditional `hidden`, so JS can show/hide it without touching the network. */
  const panel = closure('const growProgrammeSwitchPanelV322=()=>{', 'const growOngoingTopicsV244=');
  assert.doesNotMatch(stripComments(panel), /\$\{pending\?`<li class="imp-note"/,
    'the confirm block must not be conditionally EMITTED — hidden with an attribute instead');
  assert.match(panel, /<li class="imp-note" data-grow-switchconfirm-v322="\$\{esc\(kind\)\}"[^>]*\$\{pending\?'':' hidden'\}>/);
});

test('V324 the `hidden` attribute is not silently lost to the row list\'s own flex layout', () => {
  /* Confirmed by driving a real click in real Chromium, not by reading source: the confirm `<li>`
     is a direct child of `.grow-setup-rewardlist-v301`, and that list's OWN
     `.grow-setup-rewardlist-v301>li{display:flex}` rule is an author rule, which wins the cascade
     over the UA `[hidden]{display:none}` stylesheet regardless of specificity — so the very first
     render of this change had the `hidden` attribute present on every row while all four sat
     visibly open on screen. Every other flex/grid list in this file already carries the same
     `[hidden]{display:none!important}` override for exactly this reason (see
     .grow-programme-row[hidden] two lines below it); this list needs its own. */
  const css = readFileSync(join(root, 'app', 'index.html'), 'utf8');
  assert.match(css, /\.grow-setup-rewardlist-v301>li\[hidden\]\{display:none!important\}/);
});

test('V324 opening or cancelling the confirmation never calls growRerenderV322', () => {
  /* growRerenderV322 is growPage() — a full re-fetch of growOverviewSnapshot and a loading-state
     wipe of outerMain. Right for the CONFIRM click (server state actually changed). Wrong for
     OPENING or CANCELLING, which change nothing anyone but this browser tab needs to know about. */
  const openHandler = closure("outerMain.querySelectorAll('[data-grow-switchtoggle-v322]')",
    "outerMain.querySelectorAll('[data-grow-switchconfirm-no-v322]')");
  const cancelHandler = closure("outerMain.querySelectorAll('[data-grow-switchconfirm-no-v322]')",
    "outerMain.querySelectorAll('[data-grow-switchconfirm-yes-v322]')");
  assert.doesNotMatch(openHandler, /growRerenderV322\(\)/, 'opening the confirmation must not re-render the page');
  assert.doesNotMatch(cancelHandler, /growRerenderV322\(\)/, 'Cancel must not re-render the page');
  assert.match(openHandler, /growSwitchSetOpenV324\(kind\)/);
  assert.match(cancelHandler, /growSwitchSetOpenV324\(''\)/);
});

test("V324 growSwitchSetOpenV324 toggles `hidden` on every row and keeps exactly one open", () => {
  const helper = closure('const growSwitchSetOpenV324=kind=>{', '};');
  assert.match(helper, /li\.hidden=li\.dataset\.growSwitchconfirmV322!==kind/,
    'every confirm row is visited — opening one must close whichever other one was open');
  assert.match(helper, /growSwitchPendingV322=kind;growSwitchErrorV322=''/,
    'the module-level flags stay in sync even though no re-render reads them until the next one');
});

test('V335 confirming the switch still writes and still repaints, quietly', () => {
  /* The one case that legitimately needs the network: state actually changes on the server, and
     other parts of the page (rewardJourney, the programme tiles) depend on the new spine.
     V335 (owner markup, photo 2: "should not refresh my entire website"): the repaint no longer
     shows the full loading-skeleton flash — growRerenderV322({quiet:true}) still re-fetches and
     swaps in fresh state, just without wiping the page first. */
  const confirmHandler = closure("outerMain.querySelectorAll('[data-grow-switchconfirm-yes-v322]')",
    '/* V229: tiles drill in');
  assert.match(confirmHandler, /writeProgrammeSwitchesWithStampConversionV384\(/);
  assert.match(confirmHandler, /growRerenderV322\(\{quiet:true\}\)/, 'a real write still repaints from the server reply');
});

test('V322 R6 the panel switches in ONE call and keeps referral_programs in step', () => {
  const handler = closure("outerMain.querySelectorAll('[data-grow-switchconfirm-yes-v322]')",
    '/* V229: tiles drill in');
  assert.match(handler, /const want=programmeSpineOnV314\(kind\)!==true/);
  assert.match(handler, /if\(want\)programmeExclusionsV322\(kind\)\.forEach\(other=>\{set\[other\]=false\}\)/,
    'the exclusion travels in the same payload, so the firm is never in a refused shape');
  assert.equal((handler.match(/writeProgrammeSwitchesWithStampConversionV384\(/g) || []).length, 1,
    'a two-step switch is what strands a pot');
  assert.match(app, /function writeProgrammeSwitchesWithStampConversionV384[\s\S]*business_switch_to_stamps_v384[\s\S]*writeProgrammeSwitchesV314/,
    'the wrapper adds the stamp conversion confirmation without creating a second ordinary switch write');
  /* nestly_v429 (B3 site 1): the companion write is gone. v425 moves referral_programs.enabled
     inside set_programmes_v314's OWN transaction, so the spine and the column the engine reads
     can no longer be two writes one of which commits without the other. What this panel still owes
     the owner is the server's verdict on what the switch just did. */
  assert.doesNotMatch(handler, /save_referral_program_v/,
    'the spine and the column move together in one server transaction; a second client write could land half of it');
  assert.match(handler, /data\?\.referral_reward_kind_now_unpayable===true/,
    'a switch that strands the referral reward has to say so');
});

/* =================================================================================================
 * COPY — the four sentences, and the locales that carry them
 * ============================================================================================== */

test('V322 the four wrong sentences are gone, declaration and reference', () => {
  /* Against the comment-stripped source: every one of these is QUOTED in the comment that records
     why it was rewritten, which is the house convention and must not make the pin vacuous. What
     must not survive is the string as CODE. */
  for (const gone of [
    'Turn on as many as you like. Each one works on its own.',
    'They do not affect each other.',
    'you thank them with store credit',
    'A full card wins a gift'
  ]) assert.ok(!code.includes(gone), `superseded copy survives: ${gone}`);
});

test('V322 the switchboard footer states the exclusivity AND the scope semantics', () => {
  const footer = topLevel('GROW_SETUP_SWITCH_FOOTER_W6I2', 'const GROW_SETUP_RAIL_W6I2');
  assert.match(footer, /The stamp card runs on its own/);
  assert.match(footer, /Nothing you leave unticked here is switched off/);
});

test('V322 every business sentence the rulings rewrote is re-keyed in zh-CN and ms', () => {
  /* WORKSPACE_COPY_V97 is keyed on the ENGLISH STRING ITSELF, so changing a sentence silently
     orphans its translations and the console falls back to English for that line. Each of these is
     a sentence the owner reads while making the decision. */
  const workspace = app.slice(app.indexOf('const WORKSPACE_COPY_V97='), app.indexOf('function workspaceTranslationV97'));
  const zh = workspace.slice(workspace.indexOf("'zh-CN':"), workspace.indexOf('  ms:Object.freeze({'));
  const ms = workspace.slice(workspace.indexOf('  ms:Object.freeze({'));
  for (const english of [
    'Which programmes do you want to set up now?',
    'Points, tiers and referral run together. The stamp card runs on its own — picking it turns points and tiers off. Nothing you leave unticked here is switched off; it just stays as it is.',
    'Customers collect stamps. You set the milestones — 3 stamps, 5, 8, as many as you like.',
    'Customers bring a friend in, and you thank them with points.',
    'What customers can use right now',
    'Points for the customer who referred',
    'What do customers get, and at how many stamps?'
  ]) {
    assert.ok(zh.includes(`'${english}':`), `zh-CN is missing: ${english}`);
    assert.ok(ms.includes(`'${english}':`), `ms is missing: ${english}`);
  }
});

test('V322 the customer referral card speaks points in all four ct() locales', () => {
  for (const key of ['referralPoints', 'referralOnePoint']) {
    assert.ok(app.split(`${key}:`).length - 1 >= 4, `${key} is missing from a locale block`);
  }
  /* And no locale's terms line still promises credit — a zh-CN card promising 余额 is the same
     broken promise in another language. */
  for (const line of app.split('\n').filter(text => /^\s*referralTerms(WithFloor)?:/.test(text))) {
    assert.doesNotMatch(line, /credit|kredit|余额|கிரெடிட்/, `still promises credit: ${line.trim()}`);
  }
});

/* =================================================================================================
 * HOUSEKEEPING — the failure mode this repo has already paid for
 * ============================================================================================== */

test('V322 the Go-live summary reports the PAYLOAD, not the scope', () => {
  /* It printed "Tier membership — off" beside a programme the publish does not touch, which is the
     screen telling the owner the very thing the ruling forbids. Four honest states now. */
  const block = closure('const switchSummaryBlockW6I2=()=>', 'const bodyHtml=()=>');
  assert.match(block, /programmeScopeSwitchesV322\(state\.switches,\{paused:state\.keepPaused===true\}\)/);
  for (const word of ['left as it is', 'turning ON', 'staying paused', 'switching OFF']) {
    assert.ok(block.includes(word), `the summary cannot say "${word}"`);
  }
  assert.doesNotMatch(stripComments(block), /on\?'ON':'off'/,
    'the two-state summary is what made an untouched programme read as switched off');
});

test('V322 no symbol this wave introduced is referenced without being declared', () => {
  /* Deleting a declaration but leaving a reference passes `node --check` and the whole suite, then
     crashes in production. Both halves, for every new symbol. */
  for (const name of ['PROGRAMME_ACCRUAL_EXCLUSIVE_V322', 'programmeExclusionsV322',
    'programmeScopeSwitchesV322', 'growPointsWordV322', 'customerReferralPointsV322',
    'growProgrammeSwitchKindsV322', 'growProgrammeSwitchPanelV322', 'growSwitchPendingV322',
    'growSwitchErrorV322', 'stampMilestonesV322', 'stampTargetFromMilestonesV322',
    'stampMilestonesHtmlV322', 'exclusiveConflictsV322', 'applyScopeToggleV322',
    'exclusiveNoticeHtmlV322', 'switchTitleV322']) {
    assert.match(code, new RegExp(`(const|let|function)\\s+${name}\\b`), `${name} is referenced but never declared`);
  }
});

test('V322 every data attribute this wave emits is read back with the right dataset casing', () => {
  /* `data-foo-w6i2` reaches the dataset as `fooW6i2`, lowercase i — the rule that made every W6I2
     toggle inert in a real browser while nineteen source pins stayed green. */
  const pairs = [
    ['data-grow-setup-exclusive-confirm-w6i2', 'growSetupExclusiveConfirmW6i2'],
    ['data-grow-switchtoggle-v322', 'growSwitchtoggleV322'],
    ['data-grow-switchconfirm-yes-v322', 'growSwitchconfirmYesV322']
  ];
  for (const [attribute, datasetKey] of pairs) {
    assert.ok(app.includes(attribute), `${attribute} is never emitted`);
    assert.ok(code.includes(`dataset.${datasetKey}`), `${attribute} is emitted but read as something else`);
  }
});
