/* V301 — the owner report of 2026-08-13: "Business owners cannot set up rewards."

   The cold start was ~13 clicks through three STACKED popups (rewardAutoSetupModal →
   rewardDialogV238 → growPubModal); closing one dumped the owner on a page they had not chosen;
   drafts piled up unpublished; and the publish confirmation could DOUBLE-OPEN — openPublishFlow
   was auto-invoked through a queueMicrotask while its own button stayed enabled, so a second
   #growPubModal duplicated the first's ids and the visible dialog's buttons were wired to the
   one underneath it.

   Owner directive: "ONE page with step subtabs (Step 1 → 2 → 3 → …), select-and-Next simplicity
   a layman can complete unaided, publish at completion, no popups."

   What this file pins:
     A. The surface exists as a VIEW of Programmes, not a new route, and is owner-gated.
     B. Four steps, and every Next SAVES through the same draft RPCs the editor uses.
     C. Publish is save(active) → preview_publish_impact → publish_loyalty_config, inline.
     D. No dialog is ever inserted from the wizard.
     E. The entry points the owner actually presses now land here.
     F. Both publish flows are re-entrancy-guarded, so the double modal cannot recur. */
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
/* The wizard is filed with the publish-diff helpers it reuses, so it sits between
   growBirthdayPendingChangesV291 and growPublishFieldRowsV170 — deliberately OUTSIDE the
   promotionsPage→growPage and growPage→Bring-back spans other suites slice on. */
const wizard = section('async function growSetupWizardV301(', 'function growPublishFieldRowsV170(');
const grow = section('async function growPage(', '/* ---------- Bring-back playbooks');
const comparison = section('async function growSetupComparisonV301(', 'async function growSetupWizardV301(');
/* Comments name every deleted symbol on purpose — that is how a later reader learns why it is
   gone — so every "no such thing survives" assertion runs against code with the prose removed. */
const stripComments = source => source
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/^\s*\/\/.*$/gm, '');
const appCode = stripComments(app);

/* ---------------- A. one page, a view of Programmes, owner-gated ---------------- */

test('V301 (a) the wizard is a real function, mounted from growPage', () => {
  /* V303: the live tier ladder is handed in rather than re-read — growPage already loaded it for
     the Tiered membership card, and a second read would be a second answer. */
  assert.match(app, /async function growSetupWizardV301\(\{host,snapshot,isCurrent,startStep=1,liveTiers=null\}\)\{/);
  /* V331: liveTiers is now the Published-only projection (loyaltyTiersV229===null preserved for a
     read failure) rather than the raw table read, since the raw read may carry History rows the
     wizard's own Tiers step must never show or resurrect. */
  assert.match(grow, /growSetupWizardV301\(\{host:\$\('growSetupHostV301'\),snapshot,isCurrent:isGrowCurrent,startStep:growSetupStepV301,\s*\r?\n?\s*liveTiers:loyaltyTiersV229===null\?null:growTiersPublishedV331\}\)/);
  // It reuses the snapshot growPage already read — no second load of the programme.
  assert.doesNotMatch(wizard, /growOverviewSnapshot\(/);
  /* V371: one constant now feeds both the view resolver and the deep-link guard. They used to be
     separate literals and drifted — V366 added 'bringback' to the resolver only, so the Bring-back
     page also mounted a deep editor surface with a view name where a draft id belongs. */
  assert.match(app, /const GROW_PROGRAMME_VIEWS_V371=Object\.freeze\(\['overview','history','offers','points','tiers','bringback','ongoing','available','settings','setup'\]\);/);
  assert.match(app, /const programmeView=GROW_PROGRAMME_VIEWS_V371\.includes\(String\(hashParam\|\|''\)\)\?String\(hashParam\):'list'/);
  assert.match(app, /const hashParamIsProgrammeView=GROW_PROGRAMME_VIEWS_V371\.includes\(String\(hashParam\|\|''\)\);/);
});

test('V301 (a) "setup" resolves as a Programmes view, and is not mistaken for a deep link', () => {
  /* V331: 'tiers' joined this allow-list when Tiered membership got its own dedicated page,
     matching the exact 3-site pattern already established for 'points' (v326). */
  // A view hash must never mount an engine surface — that crashed on the surface dictionary.
  // The three V271/V294 rail children keep resolving exactly as before.
  assert.match(app, /views:\[\['Overview','#\/grow\/overview','reports'\],\['Rewards Programme','#\/grow','menu'\],\s*\['Limited Offer','#\/grow\/offers','loyalty'\],\['History','#\/grow\/history','waitlist'\]\]/);
  // The view replaces the category list rather than stacking on it.
  assert.match(app, /const growCategoryViewV271=!\['overview','history','setup','offers','points','tiers','bringback'\]\.includes\(programmeView\);/);
  assert.match(grow, /programmeView==='setup'\?'Set up rewards'/);
});

test('V301 (a) #/grow/setup/review opens the wizard on its final step', () => {
  /* V303: 'review' is a NAME now, not the number 4. A tier model runs FIVE steps, so a hardcoded 4
     would have opened the Reward step and called it the publish gate. The wizard resolves the name
     against whichever step list its chosen model is running. */
  assert.match(app,
    /const growSetupStepV301=programmeView==='setup'&&String\(routedFocus\|\|''\)==='review'\?'review':1;/);
  assert.match(wizard, /state\.step=String\(startStep\)==='review'\?railCountW6I2\(\)/);
});

test('V301 (a) a non-owner or a workspace without loyalty gets the read-only empty state', () => {
  assert.match(grow, /\$\{programmeView==='setup'\?\(canSetupGrow\s*\r?\n?\s*\?'<div id="growSetupHostV301"><\/div>'\s*\r?\n?\s*:CUI\.emptyState\(/);
  assert.match(grow, /if\(programmeView==='setup'&&canSetupGrow\)\{/);
  // canSetupGrow is the module's own owner + write gate, unchanged.
  assert.match(app, /const canSetupGrow=isOwner&&canRewards&&canWriteModule\('loyalty'\);/);
});

/* ---------------- B. four steps, and every Next saves ---------------- */

test('W6I2 (b) the stepper renders one mini-rail per switched-on programme, in customer order', () => {
  /* W6 increment 2 replaces three fixed step lists with ONE composed rail. Sixteen subsets of four
     switches cannot be served by a list per model, and a firm running points AND stamps needs both
     rails on screen at once — which is the state the exclusive pick could not express at all. */
  /* V322 (OWNER RULING R5 — "stamps is like a quest … 3 stamp = xx rewards, 5 stamp = xx rewards,
     8 stamp = xx rewards … able to do it customisable"): the stamps rail's second screen is no
     longer one prize at the end of a fixed card, so its label moved from 'Stamp gift' to
     'Milestones'. The claim this line makes — ONE composed rail, one entry per programme, in the
     customer-facing order STAMPS → POINTS → TIER → REFERRAL, with honest per-programme screen
     counts — is unchanged; only the second stamps screen's name moved. Matched against appCode
     because the ruling put its rationale in a comment INSIDE the array literal. */
  /* V334: Earning + Expiry merged into one 'earnExpiry' rail step for points (owner markup
     2026-08-15 photo 6) — the rest of the composed-rail claim this test protects is unchanged. */
  assert.match(appCode, /const GROW_SETUP_RAIL_W6I2=\[\s*\r?\n?\s*\['stamps',\[\['stampEarn','Stamps'\],\['stampGift','Milestones'\]\]\],\s*\r?\n?\s*\['points',\[\['earnExpiry','Earning & expiry'\],\['reward','Gifts'\]\]\],\s*\r?\n?\s*\['tiers',\[\['climb','Climbing'\],\['tiers','Tiers'\]\]\],\s*\r?\n?\s*\['referral',\[\['referral','Referral'\]\]\]\s*\r?\n?\s*\];/);
  // Screen 0 first, Go-live last, and every switched-on programme's screens in between.
  assert.match(wizard, /const steps=\[\{kind:'choose',label:'Programmes',programme:null\}\];/);
  assert.match(wizard, /if\(state\.switches\[programme\]!==true\)return;/);
  assert.match(wizard, /steps\.push\(\{kind:'live',label:'Go live',programme:null\}\);/);
  // The three fixed lists are gone from the whole file — a survivor is a rail that cannot compose.
  for (const gone of ['GROW_SETUP_STEPS_V301', 'GROW_SETUP_STEPS_TIERS_V303',
                      'GROW_SETUP_STEPS_TIERSONLY_V305', 'stepListV303', 'stepCountV303'])
    assert.doesNotMatch(app, new RegExp(`(const|function)\\\\s+${gone}\\\\b`), `${gone} is declared`);
  // The body follows the step's KIND, never its number.
  assert.match(wizard, /return kind==='choose'\?stepOneHtml\(\)/);
  assert.match(wizard, /:kind==='earn'\|\|kind==='stampEarn'\?stepTwoHtml\(\)/);
  assert.match(wizard, /:kind==='climb'\?climbStepHtmlV305\(\)/);
  /* V322 (OWNER RULING R5): the two screens SPLIT. 'reward' still renders the points catalogue;
     'stampGift' renders the milestone ladder (stampMilestonesHtmlV322), because a stamp card is a
     quest with an ordered, unbounded list of milestones and not one prize at the end of a fixed
     card. The fact this test protects — the body follows the step's KIND, never its number — is
     untouched, and the split is a second kind honouring it rather than an exception to it. */
  assert.match(wizard, /:kind==='stampGift'\?stampMilestonesHtmlV322\(\)/);
  assert.match(wizard, /:kind==='reward'\?stepThreeHtml\(\)/);
  assert.match(wizard, /data-grow-setup-goto-v301="\$\{number\}"/);
  // Completed steps carry a tick and stay clickable; unvisited ones are not yet reachable.
  assert.match(wizard, /const number=index\+1,done=number<state\.step,current=number===state\.step;/);
  assert.match(wizard, /const reachable=state\.visited\.has\(number\)\|\|number<state\.step;/);
  assert.match(wizard, /\$\{done\?'✓':number\}/);
  // 44px tap targets and a strip that scrolls rather than wrapping at 390px.
  assert.match(html, /\.grow-setup-step-v301\{[^}]*min-height:44px/);
  assert.match(html, /\.grow-setup-steps-v301\{[^}]*overflow-x:auto/);
});

test('V301 (b) each step Next writes through the SAME draft RPCs the editor writes through', () => {
  // One writer for the whole wizard.
  assert.match(wizard, /const saveDraft=async config=>\{/);
  assert.match(wizard, /sb\.rpc\('create_loyalty_config_draft',\{\s*\r?\n?\s*p_business:S\.biz\.id,p_based_on:state\.basedOn,p_source:'owner_setup_wizard_v301'\}\)/);
  assert.match(wizard, /sb\.rpc\('save_loyalty_config_draft',\{\s*\r?\n?\s*p_version:state\.versionId,p_config:config,p_expected_snapshot_hash:state\.snapshotHash\|\|null\}\)/);
  // The hash is refreshed from every response, so consecutive saves are not stale.
  assert.match(wizard, /state\.snapshotHash=data\?\.snapshot_hash\|\|null;/);
  // No second writer for the CONFIGURATION: the wizard never touches loyalty_programs directly.
  assert.doesNotMatch(wizard, /from\('loyalty_programs'\)/);
  /* V303/V314: the programme switch is the one exception, and it is deliberate. It is an INSTANT
     live change, enforced server-side, not a draft field, so throwing it at step 1 would change
     what customers can do the moment a card was pressed — before the owner reviewed anything and
     even if they then walked away. It is applied ONCE, after publish_loyalty_config has succeeded.
     V314 (W6 increment 1) moved the STORAGE only: the businesses.points_mode write became a
     public.set_programmes_v314 call, because after the switchboard inversion the spine is the
     authority and points_mode is frozen behind a swallow+audit tripwire.
     V314 REMEDIATION (2026-08-14): the call itself moved OUT of the wizard to module scope. An
     adversarial review found the wizard was one of FOUR doors onto this decision and the only one
     that reached the engine — the Grow editor's toggle still wrote the frozen column, and the two
     publish routes wrote nothing. A per-door copy of the call is exactly what let that happen, so
     there is now ONE writer and the wizard calls it. */
  assert.match(app, /sb\.rpc\('set_programmes_v314',\{\s*\r?\n?\s*p_business:businessId,p_switches:switches,p_idempotency_key:key\|\|crypto\.randomUUID\(\)\}\)/);
  /* V322 (OWNER RULING R6 — "if i unselect the program does not mean i want to turn off (i need a
     seperate button) — it just means i do not want to edit the rewards at this point in time").
     The wizard used to hand the writer `{...state.switches}`: all four kinds every time, so an
     owner who unticked Tier merely to skip two screens had their LIVE tier programme switched off
     for every customer. Screen 0 is SCOPE now, and the scope→payload translation
     (programmeScopeSwitchesV322) is what goes to the writer. The keepPaused fact this line has
     always carried survives verbatim, it just moved INTO the translation — a SELECTED kind under
     "keep it paused" is still sent `false` — which is why the writer's own paused flag is now
     false: applying it twice would pause kinds the payload had already decided. */
  assert.match(wizard, /await writeProgrammeSwitchesV314\(S\.biz\.id,\s*\r?\n?\s*programmeScopeSwitchesV322\(state\.switches,\{paused:state\.keepPaused===true\}\),\s*\r?\n?\s*\{paused:false,key:state\.switchKeyV314\}\)/);
  // And the wizard is not allowed to go back to sending the raw scope as if it were a switch set.
  assert.doesNotMatch(wizard, /writeProgrammeSwitchesV314\(S\.biz\.id,\{\.\.\.state\.switches\}/);
  const publishStep = wizard.slice(wizard.indexOf("const activeResult=await saveDraft({active:"));
  assert.ok(publishStep.indexOf("publish_loyalty_config") < publishStep.indexOf('applyProgrammeSwitchesV314(false)'),
    'the switches may only be applied AFTER the publish they belong with');
  // Publishing happened, so a failed switch write must say so rather than report a failed publish.
  assert.match(wizard, /Published\. The programme switch could not be applied/);
  assert.match(wizard, /id="growSetupModeRetryV303"/);
  /* The retry reuses ONE key, so a retry after a timeout that had actually succeeded replays the
     server's receipt instead of flipping a second time — while a SECOND publish in the same wizard
     run ("Add another reward", possibly with a different pause choice) mints a fresh key instead
     of colliding with the first receipt's request hash or silently replaying it. */
  assert.match(wizard, /if\(!fromRetry\|\|!state\.switchKeyV314\)state\.switchKeyV314=crypto\.randomUUID\(\);/);
  // And no confirm(): step 1 WAS the deliberate act, and the Go-live step states the change first.
  assert.match(app, /const PROGRAMME_SWITCHES_V314=\{/);
});

test('V301 (b) step 1 persists only a CHANGED model, and never a partial fresh one', () => {
  /* W6 increment 2: loyalty_model is decided by the SWITCHES, not by a family. Stamps ALONE is a
     stamps firm; with points or tiers also on, the catalogue is the points one. 'classic' survives
     for the firms on the fixed redeem pair — orphaning that pair breaks their one reward. */
  assert.match(wizard, /const modelForSwitchesW6I2=\(\)=>\{/);
  assert.match(wizard, /if\(state\.switches\.stamps===true&&state\.switches\.points!==true&&state\.switches\.tiers!==true\)\s*\r?\n?\s*return 'stamps';/);
  assert.match(wizard, /return baseModel&&baseModel!=='stamps'\?baseModel:'points_tiers';/);
  assert.match(wizard, /if\(model===baseModel\)return goto\(state\.step\+1\);/);
  assert.match(wizard, /const result=await saveDraft\(\{loyalty_model:model\}\);/);
});

test('W6I2 (b) screen 0 is a SWITCHBOARD: four independent toggles, any subset on', () => {
  /* The owner ruling (FOUR-PROGRAMME-INDEPENDENCE-PLAN §2-3): four programmes, each strictly
     independent, any subset live at once. The old control was a role="radiogroup" of four
     exclusive models — a shape that PROMISES picking one un-picks the others, which after the
     v314 inversion is simply false. */
  assert.match(app, /const GROW_SETUP_SWITCHES_W6I2=\[/);
  for (const [kind, title] of [['points', 'Points & gifts'], ['tiers', 'Tier membership'],
    ['stamps', 'Stamp card'], ['referral', 'Referral']])
    assert.ok(app.includes(`['${kind}','`) && app.includes(`','${title}',`),
      `the switchboard must offer ${title}`);
  // role="checkbox", not role="radio" in a radiogroup — independently pickable, not exclusive.
  assert.match(wizard, /role="group" aria-label="Programmes"/);
  /* V324 (owner, twice): "selecting or deselecting is not the same as on/off". Was role="switch" —
     WAI-ARIA's own definition of a switch is a control with immediate live effect, which this one
     never has (nothing is written until Go-live; see the untouched assertion at line ~243 below).
     role="checkbox" keeps the exact property this test exists to protect — independently pickable,
     not a radiogroup — without borrowing the vocabulary of the live on/off control one page over
     (data-grow-switchtoggle-v322, which correctly keeps role="switch"). */
  assert.match(wizard, /role="checkbox" aria-checked="\$\{on\}" data-grow-setup-switch-w6i2="\$\{esc\(kind\)\}"/);
  assert.doesNotMatch(wizard, /role="radiogroup" aria-label="Programme model"/);
  // The twelve-row integrity matrix and the four-model table are gone from the whole file.
  for (const gone of ['GROW_SETUP_MODELS_V303', 'GROW_SETUP_INTEGRITY_V305', 'integrityLineHtmlV305'])
    assert.doesNotMatch(app, new RegExp(`(const|function)\\\\s+${gone}\\\\b`), `${gone} is declared`);
  /* One footer sentence replaces the matrix, unconditionally — it is true of every state now.
     V322 (OWNER RULINGS R2/R3/R6). The sentence it used to pin — "You can turn any of these on or
     off later, on their own. They do not affect each other." — is now false in BOTH halves, and
     saying either of them on the screen the owner decides on is how the decision goes wrong:
       · R6: screen 0 is not a turn-on control at all, it is SCOPE. So the footer has to say that
         leaving something unticked does NOT switch it off.
       · R2/R3 ("stamps is not supposed to be able to be live with points and tier - it is
         seperate rewards by itself"): the stamp card DOES affect the others. So the footer has to
         say so before the owner picks it.
     The fact this test protects — screen 0 states its own semantics in one unconditional sentence
     rather than a twelve-row matrix — is unchanged; the sentence had to move because the
     semantics did. */
  assert.match(app, /const GROW_SETUP_SWITCH_FOOTER_W6I2=\s*\r?\n?\s*'Points, tiers and referral run together\. The stamp card runs on its own — picking it turns '\s*\r?\n?\s*\+'points and tiers off\. Nothing you leave unticked here is switched off; it just stays as it is\.';/);
  assert.match(wizard, /data-grow-setup-switchfoot-w6i2>\$\{esc\(GROW_SETUP_SWITCH_FOOTER_W6I2\)\}/);
  // The retired sentence must not come back: both of its promises are now untrue.
  assert.doesNotMatch(app, /You can turn any of these on or off later, on their own\./);
  /* A toggle flips ONE switch and leaves the other three alone. This is the single assertion that
     would have caught an exclusive control wearing switch clothing. "Any subset" now means any
     subset the R2/R3 accrual exclusivity permits (points | tier | points+tier | stamps, referral
     orthogonal to all four) — and the exclusion is never a silent side effect of a press. */
  assert.match(wizard, /state\.switches=\{\.\.\.state\.switches,\[kind\]:state\.switches\[kind\]!==true\};/);
  /* V322 (R2/R3): a press whose kind excludes something already ticked ARMS a named confirmation
     and flips NOTHING; the flip happens on the confirm, where the clearing becomes the owner's own
     act. Unticking never excludes anything, so it stays immediate. */
  assert.match(wizard, /if\(state\.switches\[kind\]!==true&&exclusiveConflictsV322\(kind\)\.length\)\{\s*\r?\n?\s*state\.pendingExclusiveV322=kind;return render\(\);/);
  assert.match(wizard, /data-grow-setup-exclusive-w6i2="\$\{esc\(kind\)\}"/);
  assert.match(wizard, /data-grow-setup-exclusive-confirm-w6i2="\$\{esc\(kind\)\}"/);
  assert.match(wizard, /data-grow-setup-exclusive-cancel-w6i2="1"/);
  // Referral is orthogonal: it excludes nothing and nothing excludes it.
  assert.match(app, /const PROGRAMME_ACCRUAL_EXCLUSIVE_V322=Object\.freeze\(\{stamps:\['points','tiers'\],points:\['stamps'\],tiers:\['stamps'\]\}\);/);
  // Nothing is written on screen 0: the toggles only re-render, which rebuilds the rail.
  const toggleHandler = wizard.slice(wizard.indexOf("host.querySelectorAll('[data-grow-setup-switch-w6i2]')"),
    wizard.indexOf("host.querySelectorAll('[data-grow-setup-basis-v305]')"));
  assert.ok(toggleHandler.length > 100, 'the toggle handler was found and sliced');
  assert.doesNotMatch(toggleHandler, /sb\.rpc|sb\.from|saveDraft/);
  // Preselected from the spine, then the hand-off (ON only), then the sector default.
  assert.match(wizard, /const handoffV303=pendingGrowSetupModelV303;pendingGrowSetupModelV303=null;/);
  assert.match(wizard, /const handoffKindW6I2=PROGRAMME_KINDS_W6I2\.includes\(String\(handoffV303\?\.kind\|\|''\)\)/);
  assert.match(wizard, /if\(handoffKindW6I2\)set\[handoffKindW6I2\]=true;/);
  assert.match(app, /const GROW_SETUP_SECTOR_DEFAULTS_W6I2=\{/);
  assert.match(wizard, /if\(PROGRAMME_KINDS_W6I2\.some\(kind=>set\[kind\]===true\)\)return set;/);
  /* Zero on: publish is refused, in words, rather than as a dead button.
     V322 (OWNER RULING R6): the refusal is worded twice now, once per screen, because screen 0 and
     the Go-live gate are asking different questions. Screen 0 is a SCOPE picker, so its empty
     state says "Nothing is ticked. Tick at least one programme to set up." — telling an owner
     there to "turn one on" would be the screen claiming a power the ruling took away from it. The
     Go-live gate keeps the on/off wording, because publishing IS the moment something goes on. */
  assert.match(wizard, /Nothing is ticked\. Tick at least one programme to set up\./);
  assert.match(wizard, /Nothing is turned on, so there is nothing to publish\. Go back to Programmes and turn one on\./);
  assert.match(wizard, /\|\|!anySwitchOnW6I2\(\)/);
  /* The toggle reads the attribute under the name the DOM actually gives it. `data-…-w6i2`
     reaches the dataset as `…W6i2` — the HTML rule uppercases only a letter directly after a
     hyphen — and reading it as `…W6I2` returns undefined, which made all four switches inert. */
  assert.match(wizard, /const kind=button\.dataset\.growSetupSwitchW6i2;/);
});

test('W6I2 (b) one running percentage across the whole sequence', () => {
  /* Plan §5: "a single running % across the whole sequence" — replacing stepCountV303()'s
     per-model count, which restarted its meaning every time the model changed. */
  assert.match(wizard, /const railPercentW6I2=\(\)=>\{/);
  assert.match(wizard, /return Math\.max\(0,Math\.min\(100,Math\.round\(\(\(state\.step-1\)\/total\)\*100\)\)\);/);
  assert.match(wizard, /data-grow-setup-percent-w6i2="\$\{railPercentW6I2\(\)\}"/);
  assert.match(wizard, /Step \$\{state\.step\} of \$\{railCountW6I2\(\)\} · \$\{esc\(railStepW6I2\(\)\.label\)\}/);
});

test('V303 (c) the Tiers step builds a ladder through the editor\u2019s own tier writer', () => {
  /* Owner: "tiered membership / stamps - still not able to build like points". Same wizard, same
     shape — a list, an inline form, a one-tap default — and the SAME
     save_loyalty_tier_draft_v143 the deep editor's Add tier button writes through. */
  assert.match(wizard, /const tiersStepHtml=\(\)=>\{/);
  assert.match(wizard, /sb\.rpc\('save_loyalty_tier_draft_v143',\{/);
  assert.match(wizard, /p_version:state\.versionId,/);
  assert.match(wizard, /p_tier:\{id:tier\.id,name:tier\.name,threshold:tier\.threshold,/);
  assert.match(wizard, /p_expected_snapshot_hash:state\.snapshotHash\|\|null\}\);/);
  /* V304: the draft must still exist before a tier is written, but the ensure now lives INSIDE
     writeTierRowV304 — the one writer the in-form button, the auto-save, Remove/Undo and Next all
     call. The assertion follows it there rather than pinning the shape of a loop that moved. */
  assert.match(wizard, /const writeTierRowV304=async tier=>\{[\s\S]{0,200}?const created=await ensureDraftV302\(\);\s*\r?\n?\s*if\(!created\.ok\)return created;/);
  assert.match(wizard, /if\(data\?\.snapshot_hash\)state\.snapshotHash=data\.snapshot_hash;/);
  // Only the tiers this session touched are written — a step that re-saved every listed tier
  // would bump the hash of rows nobody edited and audit a wizard write for each of them.
  assert.match(wizard, /const pending=state\.tiers\.filter\(tier=>state\.tiersDirty\.has\(tier\.id\)\);/);
  // A tier model cannot leave this step with no ladder at all.
  assert.match(wizard, /state\.error='Add at least one tier customers can reach\.';/);
  // The list is LIVE tiers merged with the draft's own versions, draft winning on id.
  assert.match(wizard, /const mergeTiersV303=\(existing,incoming\)=>\{/);
  /* Every column the two-field form does not show is handed straight back, never blanked. V304:
     `active` is now the row's own, because the SAME writer performs Remove (active:false) and Undo
     (active:true) — hardcoding true would have made removal unwritable through it. */
  assert.match(wizard, /points_multiplier:tier\.multiplier,perk_note:tier\.perkNote,sort:tier\.sort,\s*\r?\n?\s*active:tier\.active!==false,/);
  /* V331: this query named a column, 'active', that never existed on loyalty_tiers -- PostgREST's
     error-not-throw behaviour on an unknown column meant EVERY read silently resolved to null (see
     the migration header and growTiersManageV331's own comment for the full production-bug audit).
     Fixed in passing: paused/deleted_at replace it, and the wizard now receives the Published-only
     projection (growTiersPublishedV331) rather than the raw table read. */
  assert.match(app, /\.select\('id,name,threshold,points_multiplier,perk_note,sort,paused,deleted_at,effective_from,expires_at'\)/);
  // The threshold is labelled in its own unit rather than left as a bare number.
  assert.match(wizard, /const tierUnitLabelV303=\(\)=>tierBasisV303\(\)==='visits'\?'Visits to reach it':'Points to reach it';/);
  // One tap fills three rows and writes nothing until Next.
  /* D7 (plan §7): Silver / Gold / Diamond, exactly three, and the wizard PRODUCES them rather
     than offering them — a ladder screen that opens empty is a ladder screen a layman leaves
     empty. No retroactive enforcement: the prefill fires only on a firm with NO ladder at all. */
  assert.match(wizard, /const TIER_DEFAULTS_V303=\[\['Silver',0\],\['Gold',200\],\['Diamond',500\]\];/);
  assert.match(wizard, /const TIER_DEFAULTS_VISITS_W6I2=\[\['Silver',0\],\['Gold',5\],\['Diamond',15\]\];/);
  assert.match(wizard, /const prefillTiersW6I2=\(\)=>\{\s*\r?\n?\s*if\(state\.switches\.tiers!==true\|\|state\.tiers\.length\)return false;/);
  assert.match(wizard, /if\(stepKindW6I2\(\)==='tiers'\)prefillTiersW6I2\(\);/);
  assert.match(wizard, /data-grow-setup-tier-default-v303/);
});

test('V301 (b) step 2 mirrors the #lsave field set, minus what belongs to publishing', () => {
  /* V305: the row build moved out of the Earning branch into programRowV305, so the tiers-only
     Climbing step writes the IDENTICAL row rather than a second, nearly-identical one. Same
     fields, one writer — the assertions follow it there. */
  assert.match(wizard, /const programRowV305=model=>\{/);
  /* W6 increment 2: expiry comes from STATE (the OWNER AMENDMENT's reachable knob), and BOTH
     engines' settings ride one version row when both switches are on — the earn loop reads the
     spine and then this row's own stamp_per_cents / earn_points_per_dollar, never loyalty_model. */
  assert.match(wizard, /expiry_mode:state\.expiryMode\};/);
  assert.match(wizard, /row\.expiry_days=row\.expiry_mode==='none'\?null:Math\.max\(1,Math\.round\(Number\(state\.expiryDays\)\|\|365\)\);/);
  assert.match(wizard, /if\(state\.switches\.stamps===true\)row\.stamp_per_cents=Math\.round\(state\.stampSpend\*100\);/);
  assert.match(wizard, /if\(model!=='stamps'\)row\.earn_points_per_dollar=state\.earn;/);
  // V262's stored cost-per-point pair, written for a fresh programme exactly as #lsave would.
  /* V375: the fixed-redeem branch that used to sit in front of this is gone, so the cost-per-point
     default is now the only writer of the pair — for every model. */
  assert.match(wizard, /if\(writesCostDefault\(\)\)\{row\.redeem_points=costBasis;row\.reward_credit_cents=Math\.round\(0\.01\*100\*costBasis\)\}/);
  assert.match(wizard, /const costBasis=Number\(base\?\.redeem_points\)>0\?Math\.round\(Number\(base\.redeem_points\)\):800;/);
  /* V305: tier_basis is read from STATE now, not straight off the stored row — the Climbing step
     and the Points + tiers basis control are how the owner sets it, and state carries the stored
     value until they do.
     V306: and it crosses the DB boundary through tierBasisToDbV306, because state carries the
     radio's spelling and the CHECK accepts only visits|spend|points_earned. */
  assert.match(wizard, /if\(model==='points_tiers'&&state\.tierBasis\)row\.tier_basis=tierBasisToDbV306\(state\.tierBasis\);/);
  assert.match(wizard, /tierBasis:tierBasisFromDbV306\(base\?\.tier_basis\),/);
  /* configuration_status and active are NOT written here — publishing owns them, and a wizard
     that set them would publish a paused programme by accident (the V258 defect). Comments are
     stripped before the check so the explanatory prose above does not satisfy it.
     V305: sliced on the helper the branch now calls, which is where those keys would have to
     appear; the V303 kind-based dispatch had already left the old `state.step===2` slice matching
     nothing at all, so this check was passing vacuously. */
  const programRow = wizard
    .slice(wizard.indexOf('const programRowV305=model=>{'), wizard.indexOf('async function advance(){'))
    .replace(/\/\*[\s\S]*?\*\//g, '');
  assert.ok(programRow.length > 200, 'the programme-row helper was found and sliced');
  assert.doesNotMatch(programRow, /configuration_status/);
  assert.doesNotMatch(programRow, /row\.active|active:/);
});

test('V301 (b) step 3 writes the reward through the saveReward envelope', () => {
  assert.match(wizard, /fulfillment_kind:'manual_item',active:true\}/);
  assert.match(wizard, /saveDraft\(\{reward:payload,reward_branch_ids:\[\],reward_service_ids:\[\],reward_product_ids:\[\]\}\)/);
  /* A fresh setup cannot leave step 3 with nothing customers can claim. V304: "nothing" now means
     nothing ACTIVE — removing every reward and pressing Next must not walk past an empty
     catalogue just because the removed rows are still on screen with Undo beside them. */
  assert.match(wizard, /if\(!hasForm&&!activeRewardsV304\(\)\.length\)\{/);
  // V293's budget → points derivation, with the same manual-override rule.
  assert.match(wizard, /pointsInput\.value=String\(Math\.max\(1,Math\.ceil\(\(budget\*100\)\/Math\.max\(1,costPerPointCents\(\)\)\)\)\)/);
  assert.match(wizard, /pointsInput\.addEventListener\('input',\(\)=>\{manualV301=true\}\);/);
  /* V375 (owner, photo 3): the classic pair had its own "what do points buy" sentence and its own
     save. Both are gone with the model — every firm now reaches the reward catalogue step. */
  assert.doesNotMatch(wizard, /classicRedeem|classicCredit/);
  /* Stamps save their target with the programme fields — through the same saveDraft envelope, on
     the same Next, which is the fact this line has always protected.
     V322 (OWNER RULING R5 — "stamps is like a quest … 3 stamp = xx rewards, 5 stamp = xx rewards,
     8 stamp = xx rewards … able to do it customisable"): the number is no longer TYPED. The card's
     length is the highest milestone on the ladder, derived after the milestone form on this press
     has been written, and sent only when it actually moved — a card whose length disagreed with
     its own last prize is the two-numbers-for-one-fact defect the ruling closes. */
  assert.match(wizard, /const target=stampTargetFromMilestonesV322\(\);/);
  assert.match(wizard, /if\(target!==state\.stampTarget\)\{\s*\r?\n?\s*state\.stampTarget=target;\s*\r?\n?\s*const result=await saveDraft\(\{stamp_target:target\}\);/);
  // A ladder with no reachable milestone cannot leave the screen with a zero-length card.
  assert.match(wizard, /Give at least one milestone a stamp count above zero\./);
  // And the typed field it replaces is gone from the milestones screen.
  assert.match(app, /const stampTargetFromMilestonesV322=\(\)=>stampMilestonesV322\(\)/);
});

test('V301 (b) a failed save keeps the owner on the step, with a retry and their values', () => {
  assert.match(wizard, /const failStep=\(error,tail\)=>\{state\.error=`\$\{ownerErrorText\(error\)\} \$\{tail\}`;render\(\)\};/);
  assert.match(wizard, /if\(!result\.ok\)return failStep\(result\.error,'Nothing was saved\.'\);/);
  assert.match(wizard, /\?`<div class="err" role="alert">\$\{esc\(state\.error\)\}[\s\S]{0,180}?id="growSetupRetryV301">Retry<\/button>/);
  // State lives in the closure, so a re-render cannot lose a typed value.
  assert.match(wizard, /const readStepFields=\(\)=>\{/);
});

/* ---------------- V304. the two list steps save themselves ----------------
   Owner, re-testing the shipped V303 build:
     "i typed the points or cost needed for points redemption - but not reflected in the system and
      not auto saved (it needs to reflect as i change it, so will not have confusion)"
     "i need to be able to add extra tier / delete tier"
     "for rewards subtab - i need to be able to add or delete. because now i need to press 'next'
      then press 'back' to view changes"
   The write was only ever performed inside advance(), so the list above the form could not change
   until the owner left the step and came back, a second row could not be added without advancing,
   and nothing could be removed at all. */

test('V304 one save helper per step, called by BOTH the in-form button and Next', () => {
  assert.match(wizard, /const saveRewardFormV304=async\(form,\{active=null\}=\{\}\)=>\{/);
  assert.match(wizard, /const saveTierFormV304=async\(form,\{active=null\}=\{\}\)=>\{/);
  assert.match(wizard, /const writeTierRowV304=async tier=>\{/);
  // The in-form primary action, inside the form card, on both steps.
  assert.match(wizard, /id="growSetupRewardSaveV304">\$\{form\.id\?'Save':'Add reward'\}/);
  assert.match(wizard, /id="growSetupTierSaveV304">\$\{editing\?'Save':'Add tier'\}/);
  const rewardButton = wizard.slice(wizard.indexOf("const rewardSaveButton=$('growSetupRewardSaveV304');"),
    wizard.indexOf("host.querySelectorAll('[data-grow-setup-reward-remove-v304]')"));
  assert.match(rewardButton, /runSaveV304\(\(\)=>saveRewardFormV304\(form\)\)/);
  const tierButton = wizard.slice(wizard.indexOf("const tierSaveButton=$('growSetupTierSaveV304');"),
    wizard.indexOf("host.querySelectorAll('[data-grow-setup-tier-remove-v304]')"));
  assert.match(tierButton, /runSaveV304\(\(\)=>saveTierFormV304\(form\)\)/);
  // ...and Next calls the SAME helpers rather than keeping a second copy of the write.
  const advanceSlice = wizard.slice(wizard.indexOf('async function advance('));
  assert.match(advanceSlice, /runSaveV304\(\(\)=>saveTierFormV304\(\{\.\.\.form\}\)\)/);
  assert.match(advanceSlice, /runSaveV304\(\(\)=>saveRewardFormV304\(\{\.\.\.form\}\)\)/);
  assert.match(advanceSlice, /runSaveV304\(\(\)=>writeTierRowV304\(tier\)\)/);
  // The reward helper still performs V302's ensure-then-edit before a partial edit is written.
  const rewardHelper = wizard.slice(wizard.indexOf('const saveRewardFormV304='),
    wizard.indexOf('const writeTierRowV304='));
  assert.match(rewardHelper, /sb\.rpc\('ensure_published_reward_in_draft_v138',\{/);
  assert.ok(rewardHelper.indexOf('ensure_published_reward_in_draft_v138') < rewardHelper.indexOf('const payload=form.id'),
    'the materialisation must precede the edit envelope');
  // The in-form button is disabled for the duration of its own write, like Next.
  assert.match(wizard, /const withBusy=async\(work,buttonId='growSetupNextV301'\)=>\{/);
  assert.match(wizard, /\},'growSetupRewardSaveV304'\);/);
  assert.match(wizard, /\},'growSetupTierSaveV304'\);/);
});

test('V304 the row reflects what is being typed, before any save', () => {
  /* "it needs to reflect as i change it, so will not have confusion" — DOM-only, on input, for a
     form that is editing a LISTED row. A per-keystroke re-render would take the caret with it. */
  assert.match(wizard, /const onRewardInput=\(\)=>\{/);
  assert.match(wizard, /const onTierInput=\(\)=>\{/);
  assert.match(wizard, /const row=host\.querySelector\(`\[data-grow-setup-rewardrow-v304="\$\{id\}"\]`\);/);
  assert.match(wizard, /nameNode\.textContent=state\.form\.name\|\|'Reward';/);
  assert.match(wizard, /pointsNode\.textContent=rewardRowPointsTextV304\(parseInt\(state\.form\.points\|\|'0',10\)\|\|0\);/);
  assert.match(wizard, /const row=host\.querySelector\(`\[data-grow-setup-tierrow-v304="\$\{id\}"\]`\);/);
  assert.match(wizard, /thresholdNode\.textContent=tierRowThresholdTextV304\(parseInt\(state\.tierForm\.threshold\|\|'0',10\)\|\|0\);/);
  /* One composer per line, used by BOTH the render and the patch — two spellings of the same
     sentence is how an optimistic update starts disagreeing with the next render. It is also
     where the v97 rule wants interpolated runtime copy: in a named function, not at a
     textContent assignment. */
  assert.match(wizard, /const rewardRowPointsTextV304=points=>/);
  assert.match(wizard, /const tierRowThresholdTextV304=threshold=>/);
  assert.match(wizard, /data-grow-setup-rewardpoints-v304>\$\{esc\(rewardRowPointsTextV304\(reward\.points\)\)\}/);
  assert.match(wizard, /data-grow-setup-tierthreshold-v304>\$\{esc\(tierRowThresholdTextV304\(tier\.threshold\)\)\}/);
  // The affix, and the transient marker the save replaces it with.
  assert.match(wizard, /rowMarkV304\('reward',id,' · editing'\);/);
  assert.match(wizard, /rowMarkV304\('tier',id,' · editing'\);/);
  assert.match(wizard, /const rowMarkTextV304=id=>state\.editingV304===id\?' · editing':'';/);
  assert.match(wizard, /const flashSavedV304=\(kind,id\)=>\{/);
  assert.match(wizard, /rowMarkV304\(kind,id,' · Saved ✓'\);/);
  // The reward listener is registered AFTER the budget→points derivation, or it would read the
  // points field one keystroke behind — that derivation writes the value without an input event.
  assert.ok(wizard.indexOf('pointsInput.value=String(Math.max(1,Math.ceil(') < wizard.indexOf('const onRewardInput=()=>{'),
    'the V304 reward input listener must be registered after the V293 derivation');
});

test('V304 an existing row auto-saves, and every save is serialised', () => {
  // Debounced, 900ms after the last keystroke, and ONLY for a row that already exists.
  assert.match(wizard, /const autoSaveRewardV304=\(\)=>\{/);
  assert.match(wizard, /const autoSaveTierV304=\(\)=>\{/);
  assert.match(wizard, /const form=state\.form\?\.id\?\{\.\.\.state\.form\}:null;\s*\r?\n?\s*if\(!form\)return;/);
  assert.match(wizard, /const form=state\.tierForm\?\.id\?\{\.\.\.state\.tierForm\}:null;\s*\r?\n?\s*if\(!form\)return;/);
  assert.match(wizard, /rewardTimerV304=setTimeout\(\(\)=>\{/);
  assert.match(wizard, /\},900\);/);
  /* One promise chain for every save. Both writers carry the snapshot hash they last read and the
     server bumps it on each write, so two in flight together means the second is stale — 40001. */
  assert.match(wizard, /let saveChainV304=Promise\.resolve\(\);/);
  assert.match(wizard, /const runSaveV304=work=>\{\s*\r?\n?\s*const next=saveChainV304\.then\(work,work\);\s*\r?\n?\s*saveChainV304=next\.then\(\(\)=>\{\},\(\)=>\{\}\);/);
  // A hash conflict is re-read and retried ONCE, silently, before the owner is told.
  assert.match(wizard, /const hashConflictV304=error=>\/40001\|snapshot\|stale\|conflict\|serial\//);
  assert.match(wizard, /const retryOnConflictV304=async write=>\{/);
  assert.match(wizard, /await refreshRewards\(\);\s*\r?\n?\s*return write\(\);/);
  // The explicit button and Next flush the pending debounce first, so one intent is one write.
  assert.match(wizard, /const flushRewardSaveV304=\(\)=>\{if\(rewardTimerV304\)\{clearTimeout\(rewardTimerV304\);rewardTimerV304=null\}\};/);
  assert.match(wizard, /const flushTierSaveV304=\(\)=>\{if\(tierTimerV304\)\{clearTimeout\(tierTimerV304\);tierTimerV304=null\}\};/);
  const advanceSlice = wizard.slice(wizard.indexOf('async function advance('));
  assert.ok(advanceSlice.indexOf('flushTierSaveV304();') < advanceSlice.indexOf('saveTierFormV304({...form})'),
    'Next must flush the tier debounce before performing the same write');
  assert.ok(advanceSlice.indexOf('flushRewardSaveV304();') < advanceSlice.indexOf('saveRewardFormV304({...form})'),
    'Next must flush the reward debounce before performing the same write');
});

test('V304 Remove writes active:false through the same writers, with Undo and no dialog', () => {
  // Every row carries Remove beside Edit, on both steps.
  assert.match(wizard, /data-grow-setup-reward-remove-v304="\$\{esc\(reward\.id\)\}">Remove<\/button>/);
  assert.match(wizard, /data-grow-setup-tier-remove-v304="\$\{esc\(tier\.id\)\}">Remove<\/button>/);
  // Removal is the archive write, through the SAME helper an ordinary save goes through.
  assert.match(wizard, /saveRewardFormV304\(\{id:reward\.id,name:reward\.name,\s*\r?\n?\s*budget:\(reward\.budgetCents\/100\)\.toFixed\(2\),points:String\(reward\.points\)\},\{active:false\}\)/);
  assert.match(wizard, /saveTierFormV304\(\{id:tier\.id,name:tier\.name,\s*\r?\n?\s*threshold:String\(tier\.threshold\)\},\{active:false\}\)/);
  // The removed row STAYS, muted, with an id-carrying Undo that re-saves active:true.
  assert.match(wizard, /class="is-removed-v304" data-grow-setup-rewardrow-v304=/);
  assert.match(wizard, /data-grow-setup-reward-undo-v304="\$\{esc\(reward\.id\)\}">Undo<\/button>/);
  assert.match(wizard, /data-grow-setup-tier-undo-v304="\$\{esc\(tier\.id\)\}">Undo<\/button>/);
  assert.match(wizard, /\{active:true\}\)\);/);
  assert.match(html, /\.grow-setup-rewardlist-v301>li\.is-removed-v304\{opacity:\.62;border-style:dashed\}/);
  // The last one cannot go: the step's own validation would strand the owner on an error.
  assert.match(wizard, /state\.error='Keep at least one tier, or switch model in Choose\.';/);
  assert.match(wizard, /state\.error='Keep at least one reward customers can get — add its replacement first\.';/);
  assert.match(wizard, /if\(tierModelW6I2\(\)&&activeTiersV304\(\)\.length<=1\)\{/);
  /* The list must be able to CARRY an archived row, or a removed reward vanishes before its Undo
     can be pressed — and the draft's active:false has to beat the published row that still says
     active, which the old pre-merge filter made impossible. */
  assert.doesNotMatch(wizard, /\.filter\(reward=>reward\?\.active!==false\)/);
  assert.match(wizard, /active:reward\?\.active!==false,/);
  assert.match(wizard, /active:tier\?\.active!==false,/);
  assert.match(wizard, /\.filter\(reward=>reward\.active!==false\),/);
  assert.match(wizard, /const activeRewardsV304=\(\)=>state\.rewards\.filter\(reward=>reward\.active!==false\);/);
  assert.match(wizard, /const activeTiersV304=\(\)=>state\.tiers\.filter\(tier=>tier\.active!==false\);/);
  /* The Go-live summary names only what a customer can still claim. V375 removed the classic
     store-credit branch that used to sit in front of this expression (owner, photo 3), so the
     reward line now opens with the very same test. */
  assert.match(wizard, /const rewardLine=\(\)=>activeRewardsV304\(\)\.length/);
});

test('V304 the copy matches the button, and no step still says "press Next to add"', () => {
  assert.doesNotMatch(wizard, /press Next to add/);
  assert.match(wizard, /Add tier saves it to the list right away\./);
  assert.match(wizard, /Add reward saves it to the list right away\./);
  assert.match(wizard, /Your changes save on their own\./);
  // Still no dialog anywhere in the wizard, which is what Undo replaces.
  const code = wizard.replace(/\/\*[\s\S]*?\*\//g, '');
  assert.doesNotMatch(code, /confirm\(/);
  assert.doesNotMatch(code, /class="modal/);
  assert.doesNotMatch(code, /CUI\.activateDialog/);
});

/* ---------------- C. publish at completion, inline ---------------- */

test('V301 (c) publish is save(active) → preview_publish_impact → publish_loyalty_config', () => {
  const publish = wizard.slice(wizard.indexOf("const activeResult=await saveDraft({active:"));
  assert.match(publish, /const activeResult=await saveDraft\(\{active:!state\.keepPaused\}\);/);
  assert.match(publish, /sb\.rpc\('preview_publish_impact',\{p_config_version_id:state\.versionId\}\)/);
  assert.match(publish, /sb\.rpc\('publish_loyalty_config',\{p_version:state\.versionId\}\)/);
  assert.ok(publish.indexOf('preview_publish_impact') < publish.indexOf('publish_loyalty_config'),
    'the impact check must precede the publish');
  // 42501 says who can publish, in words.
  assert.match(publish, /publishError\.code==='42501'\?'Only the owner can publish\.'/);
});

test('V301 (c) the programme defaults ON, with an explicit way to keep it paused', () => {
  assert.match(wizard, /Programme will be ON — customers start earning when you publish\./);
  assert.match(wizard, /id="growSetupPauseV301"[^>]*>[\s\S]{0,60}?Keep it paused for now/);
  assert.match(wizard, /keepPaused:false,/);
});

test('V301 (c) the acknowledgement is INLINE and gates the button, never a dialog', () => {
  assert.match(wizard, /if\(\(impact\?\.requires_confirmation===true\|\|rules\.length>0\)&&!state\.ack\)\{/);
  assert.match(wizard, /state\.needAck=true;state\.impactRules=rules;return render\(\);/);
  assert.match(wizard, /id="growSetupAckV301"/);
  // Same wording as the existing gate.
  assert.match(wizard, /I have read the changes above and want customers to get them now\./);
  /* W6 increment 2: four reasons can now block the button and they are collected in ONE
     predicate — the advanced-rule tick, D3's member-movement tick, "nothing is turned on", and a
     points-earned ladder with the points programme off (a ladder that can never move). */
  assert.match(wizard, /const publishBlockedW6I2=\(\)=>stepKindW6I2\(\)==='live'/);
  assert.match(wizard, /&&\(\(state\.needAck&&!state\.ack\)\|\|\(tierMovementRiskW6I2\(\)&&!state\.tierAck\)\|\|!anySwitchOnW6I2\(\)/);
  assert.match(wizard, /\|\|pointsLadderStalledW6I2\(\)\);/);
  assert.match(wizard, /id="growSetupNextV301"\$\{publishBlockedW6I2\(\)\?' disabled':''\}/);
});

test('V301 (c) the change list reuses the publish gate’s own comparison helpers', () => {
  for (const helper of ['growPublishFieldRowsV170', 'growRewardPendingChangesV291',
    'growRetentionPendingChangesV291', 'growBirthdayPendingChangesV291',
    'growRewardDiffOptionsFromSnapshotV291', 'growAttachEligibilityV291', 'growAttachDraftEligibilityV291'])
    assert.match(comparison, new RegExp(helper), `the comparison must reuse ${helper}`);
  // The publish is bundle-wide, so birthday and bring-back changes are listed too.
  assert.match(comparison, /pushChange\('Birthday benefit',change\.label,change\.live,change\.pending\)/);
  assert.match(comparison, /new bring-back rule, starts when you publish/);
  // Fail-soft: an unreadable section is NAMED, never reported as "nothing changed".
  assert.match(comparison, /const unreadable=\[diff\.rewards\?'':'rewards',diff\.retention\?'':'bring-back rules',diff\.birthday\?'':'the birthday benefit'\]\.filter\(Boolean\);/);
  assert.match(wizard, /could not be read, so they are not listed here/);
});

test('V301 (c) success replaces the wizard body and offers exactly two ways on', () => {
  assert.match(wizard, /Published — customers can use this now/);
  /* V335: the destination/label vary for the Points System page's own single-screen entry — see
     the dedicated 'V335 simpleEditModeV335' tests below. This asserts the DEFAULT (multi-step
     setup) path, unchanged. */
  assert.match(wizard, /<a class="btn" href="\$\{state\.simpleEditModeV335\?'#\/grow\/points':'#\/grow\/overview'\}" id="growSetupDoneV301">\$\{state\.simpleEditModeV335\?'Back to Points System':'Back to Programmes'\}<\/a>/);
  assert.match(wizard, /id="growSetupAddAnotherV301">Add another reward<\/button>/);
  // The published version is no longer a draft, so a further edit starts a new one.
  assert.match(wizard, /state\.published=true;state\.versionId=null;state\.snapshotHash=null;state\.basedOn=null;/);
  assert.match(wizard, /toast\('Grow changes published'\);/);
});

/* ---------------- D. no popups ---------------- */

test('V301 (d) the wizard never inserts a dialog', () => {
  /* V303: comments are stripped before the check, the same way step 2's field-set check strips
     them, so the explanatory prose that NAMES confirm() cannot satisfy — or fail — an assertion
     about the code. */
  const code = wizard.replace(/\/\*[\s\S]*?\*\//g, '');
  assert.doesNotMatch(code, /class="modal/);
  assert.doesNotMatch(code, /insertAdjacentHTML\('beforeend'/);
  assert.doesNotMatch(code, /CUI\.activateDialog/);
  assert.doesNotMatch(code, /openRewardDialogV238/);
  assert.doesNotMatch(code, /confirm\(/);
  // It renders into the Programmes card, not the body.
  assert.match(wizard, /host\.innerHTML=`<section class="grow-setup-v301"/);
});

/* ---------------- E. the entries the owner presses ---------------- */

test('V301 (e) the rewards cold start no longer opens the auto-setup modal', () => {
  assert.match(grow, /if\(canSetupGrow&&!growProgrammeExistsV258&&action\.surface==='rewards'\)return nav\('#\/grow\/setup'\);/);
  const gate = grow.slice(grow.indexOf('const openGrowEditorV258=async(action)=>{'),
    grow.indexOf("document.querySelectorAll('[data-welcome-offer-edit-v215]')"));
  // The rewards branch is the wizard; openRewardsAutoSetup survives only for the Bring-back
  // cold start, which is a different engine with no wizard of its own.
  assert.ok(gate.indexOf("action.surface==='rewards'") < gate.indexOf('openRewardsAutoSetup'),
    'the rewards branch must be decided before the auto-setup fallback');
  assert.match(app, /function openRewardsAutoSetup\(/);
});

test('V301 (e) the pending point-engine cards and the bare Point system row open the wizard', () => {
  /* V302 (owner, on the shipped V301, from a workspace whose programme is PAUSED with four
     rewards: "it still showing gift card and same UI UX"). The V301 gate excluded a paused
     catalogue as "a configured programme its owner is managing" — but paused is the state a
     failed setup ATTEMPT ends in, so the one workspace that reported the bug was the one state
     the fix could not reach. Anything not LIVE is unfinished setup. Capability is preserved by
     the wizard's permanent link into the full editor, asserted here, not by withholding the
     wizard from the owner who needs it. */
  /* V303 (owner 2026-08-13, third round, re-testing from a workspace whose programme is now LIVE:
     "tiered membership / stamps - still not able to build like points"). The V302 line still ended
     in "&&!loyaltyLive", so the moment a programme went live all three cards fell back to the old
     drill — and the Tiered membership card fell back to a drill whose first row reads "Tier
     membership is off". Two scope narrowings have now been reverted by the owner in two rounds, so
     this one goes too: the wizard IS this module's UX, for the first set-up and for editing, live
     or not, and it opens PREFILLED from whatever is live. 'tiers' joins the list because a ladder
     must be buildable the same way points are. The ABSENCE of the live gate is asserted. */
  assert.match(grow, /const growSetupEntryV301=key=>canSetupGrow&&\['points','stamps','tiers'\]\.includes\(String\(key\|\|''\)\);/);
  assert.doesNotMatch(grow, /growSetupEntryV301=key=>[^\n]*loyaltyLive/);
  /* V364 (owner: "remove this everywhere"): the wizard's "More reward settings" link went with
     the block it opened. The deep editor route itself is untouched. */
  assert.doesNotMatch(app, /id="growSetupFullEditorV302"/);
  assert.doesNotMatch(app, /More reward settings<\/a>/);
  // The card that was pressed decides which model the wizard opens on.
  /* The card key rides along with the model: the model is what the wizard EDITS, the card is
     which programme the owner came ABOUT — and that is what V294's editor entry context means.
     A firm running points+tiers opens the Points System card on the 'both' model, and its full
     editor must still be the points one. */
  /* W6 increment 2: the tile hands over a PROGRAMME KIND, and it can only ever turn that switch
     ON. growSetupModelForTileV303 answered "which of four exclusive models is this card", which
     meant opening the Stamp card tile proposed a live points programme OFF. Every other switch now
     keeps whatever the spine says.
     V331: the TILE itself no longer builds this hand-off at all (points/stamps/tiers each go
     straight to their own dedicated page, never through growSetupEntryV301). What still holds is
     the ON-only, from-carrying SHAPE of the hand-off — now built by each page's own Setup/Edit
     controls (growPointsSetupCta/growPointsEditCta/growTiersSetupCta/growTiersEditLink) instead of
     the tile click. growSetupKindForTileW6I2 is consequently unused in app.js — its definition is
     left in place rather than deleted, since deleting it would touch nothing this session actually
     changed about its own behaviour. */
  /* V331/V359 retired this hand-off: the points/stamps and tiers tiles route to their own pages,
     which turn a programme on by calling set_programmes_v314 directly and edit the earning rule
     inline, so nothing builds the ON-only kind:from shape any more. The consumer inside the wizard
     is still pinned above (line ~260) and is asserted to have no writer left. */
  assert.doesNotMatch(app, /pendingGrowSetupModelV303\s*=\s*\{/);
  assert.match(app, /if\(tile\.dataset\.growTopicV229==='tiers'\)return nav\('#\/grow\/tiers'\);/);
  assert.match(wizard, /const editorContextV303=\(\)=>handoffV303\?\.from/);
  assert.match(wizard, /\?\(handoffV303\.from==='tiers'\?'ctx-tiers':'ctx-points'\)/);
  assert.match(grow, /const growSetupKindForTileW6I2=key=>key==='stamps'\?'stamps':key==='tiers'\?'tiers':'points';/);
  assert.doesNotMatch(appCode, /growSetupModelForTileV303/);
  // The replacement word on an off programme: nothing is replaced any more.
  assert.match(grow, /if\(label==='Off'\)return 'Turn on →';/);
  assert.doesNotMatch(appCode, /'Switch to this →'/);
  // "Set up →" while this model is not reaching customers, "Edit →" once it is.
  assert.match(grow, /if\(growSetupEntryV301\(topic\.key\)\)return growTopicOngoingV244\(topic\)\?'Edit →'/);
  assert.match(grow, /if\(kind==='earning'&&!rewardJourney\.earning&&canSetupGrow\)return nav\('#\/grow\/setup'\);/);
  // The drill is still what a non-point-engine card opens.
  assert.match(grow, /growTopicV229=tile\.dataset\.growTopicV229;/);
});

test('V303 (e) Add reward and per-reward Edit never open a dialog again', () => {
  /* Owner 2026-08-13: "pressing add rewards - still brings me to this page", screenshotting the
     old New-reward dialog opened from a LIVE programme's drill. No primary path may open a
     dialog: both reward controls on the grid go to the wizard's Reward step with the inline form
     armed, and the deep editor keeps its dialogs behind "More reward settings". */
  assert.match(grow, /if\(canSetupGrow&&\(kind==='add'\|\|kind==='catalogue'\)&&!button\.closest\('\[data-reward-history-v294\]'\)\)\{/);
  assert.match(grow, /pendingGrowSetupRewardV303=kind==='add'\s*\r?\n?\s*\?\{mode:'add'\}\s*\r?\n?\s*:\{mode:'edit',id:button\.dataset\.rewardId\|\|null\};/);
  /* The wizard consumes it ONCE and opens on the Reward step with that reward loaded.
     V305: and only when the chosen model HAS a Reward step. Tiers-only does not, and the old
     stepNumberForV303 fallback ("the last step") would have dropped the owner on the publish gate
     with a reward form armed.
     V326: the up-front gate moved inline — the declaration now unconditionally reads the
     one-shot, and the Reward-step check guards the reward/edit/add branch specifically,
     alongside the new mode:'earning' branch's own guard on the 'earn' step (the Points System
     page's "edit" link). Same invariant, reached a different way now a second mode exists. */
  assert.match(wizard, /const rewardHandoffV303=pendingGrowSetupRewardV303;\s*\r?\n?\s*pendingGrowSetupRewardV303=null;/);
  assert.match(wizard, /\}else if\(rewardHandoffV303&&stepNumberOrNullW6I2\('reward'\)!==null\)\{/);
  assert.match(wizard, /state\.step=stepNumberForW6I2\('reward'\);/);
  assert.match(wizard, /\?state\.rewards\.find\(reward=>reward\.id===String\(rewardHandoffV303\.id\|\|''\)\)/);
  // "Add another reward" on the success panel lands on the same step, wherever it is numbered.
  assert.match(wizard, /goto\(stepNumberForW6I2\('reward'\)\);/);
  // ...and is not offered at all where there is no Reward step to go back to.
  assert.match(wizard, /\$\{stepNumberOrNullW6I2\('reward'\)===null\?'':'<button type="button" class="btn ghost sm" id="growSetupAddAnotherV301">Add another reward<\/button>'\}/);
  /* Reward HISTORY cards carry the same contract but the job there is un-archiving, which the
     wizard's three-field form cannot do and does not show — so those keep the full editor. */
  assert.match(app, /data-reward-history-v294/);
});

test('V301 (e) both unpublished-changes banners route to the wizard’s final step', () => {
  // The old review page is NOT deleted — the studio rule builder still links it.
  assert.match(app, /function openProtectedGrowPublishReview\(draftVersionId\)\{/);
  assert.match(app, /async function studioPublishReviewPage\(routeMain,isCurrent,draftVersionId\)\{/);
  assert.match(app, /nav\(`#\/studio\/\$\{draftVersionId\}`\)/);
  // ...and the wizard's own step 4 replaces the banner on that page, so there is one door.
  /* V358 struck the unpublished-changes banner out entirely (owner: "remove this entirely from my
     codebase"), so the marker resolves to the empty string and there is no banner left to route.
     The review page itself is deliberately kept — the Studio rule builder still links it. */
  assert.match(grow, /const growUnpublishedMarkerV198='';/);
});

/* ---------------- F. the double publish modal cannot recur ---------------- */

test('V301 (f) the Grow publish flow is re-entrancy guarded and disables its trigger', () => {
  const review = section('async function studioPublishReviewPage(', 'async function studioPage(');
  assert.match(review, /let growPublishFlowBusyV301=false;/);
  assert.match(review, /if\(growPublishFlowBusyV301\|\|document\.getElementById\('growPubModal'\)\)return;/);
  assert.match(review, /const releaseV301=\(\)=>\{/);
  // The trigger stays disabled for the whole queued auto-open, not just for the RPC inside it.
  assert.match(review, /const growPublishTriggerV301=\$\('growPublishReview'\);/);
  assert.match(review, /if\(growPublishTriggerV301\)\{growPublishTriggerV301\.disabled=true;growPublishTriggerV301\.setAttribute\('aria-busy','true'\)\}/);
  assert.match(review, /queueMicrotask\(async\(\)=>\{await comparisonReadyV258;if\(isCurrent\(\)\)openPublishFlow\(\)\}\);/);
  // Closing the dialog is what re-enables it.
  assert.match(review, /const close=\(\)=>\{if\(deactivate\)deactivate\(\);else \$\('growPubModal'\)\?\.remove\(\);releaseV301\(\)\};/);
});

test('V301 (f) the Studio rule builder’s publish flow carries the same guard', () => {
  assert.match(app, /let studioPublishFlowBusyV301=false;/);
  assert.match(app, /if\(studioPublishFlowBusyV301\|\|document\.getElementById\('studioPubModal'\)\)return;/);
  assert.match(app, /const studioPublishTriggerV301=\$\('studioPublish'\);/);
  assert.match(app, /function renderPublishImpactDialog\(impact,releaseTriggerV301=\(\)=>\{\}\)\{/);
  assert.match(app, /const close=\(\)=>\{if\(deactivate\)deactivate\(\);else \$\('studioPubModal'\)\?\.remove\(\);releaseTriggerV301\(\);\};/);
});

/* ---------------- G. V305: four scenarios, four step lists, and integrity said out loud ------- */

test('W6I2 (g) the rail composes, and a programme turned off takes its screens with it', () => {
  /* The owner report V305 answered — "when i press 'tiered membership' - it shows both tier &
     points?" — was that a fixed step list showed screens the chosen model could not honour. The
     switchboard answers it structurally: a screen is on the rail if and only if its programme is
     switched on, so there is no subset for which the rail can be wrong. */
  assert.match(wizard, /const railW6I2=\(\)=>\{/);
  assert.match(wizard, /const railCountW6I2=\(\)=>railW6I2\(\)\.length;/);
  assert.match(wizard, /const railStepW6I2=\(\)=>railW6I2\(\)\[state\.step-1\]\|\|\{kind:'live',label:'Go live',programme:null\};/);
  assert.match(wizard, /const stepKindW6I2=\(\)=>railStepW6I2\(\)\.kind;/);
  // Customer-facing order, pinned: STAMPS → POINTS & GIFTS → TIER → REFERRAL (W4 stack order).
  const rail = app.slice(app.indexOf('const GROW_SETUP_RAIL_W6I2=['), app.indexOf('const GROW_SETUP_SECTOR_DEFAULTS_W6I2='));
  assert.deepEqual([...rail.matchAll(/^\s*\['(stamps|points|tiers|referral)',\[/gm)].map(m => m[1]),
    ['stamps', 'points', 'tiers', 'referral']);
  /* Turning a switch off mid-rail rebases the visited set and returns to screen 0. A step number
     that meant "Gifts" a moment ago can mean "Tiers" now, and carrying the old set forward would
     unlock a screen the owner has never seen. */
  assert.match(wizard, /state\.visited=new Set\(\[1\]\);\s*\r?\n?\s*state\.step=1;/);
  // The engine each screen speaks is a property of the SCREEN, not of the whole wizard — which is
  // what lets points and stamps both be on the rail without either re-labelling the other.
  assert.match(wizard, /const familyW6I2=\(\)=>railStepW6I2\(\)\.programme==='stamps'\?'stamps':'points';/);
  assert.doesNotMatch(appCode, /state\.family/);
  assert.doesNotMatch(appCode, /state\.pick/);
  assert.match(wizard, /data-grow-setup-step-v301="\$\{state\.step\}"/);
});

test('W6I2 (g) the tier basis is a first-class CHOICE — owner amendment 2026-08-14', () => {
  /* The W6 design contract §1.3 had this control deleted and every ladder forced onto points
     earned. The OWNER AMENDMENT overrides it: "a firm may climb its ladder by VISITS or by POINTS
     EARNED (points-earned stays the default the wizard suggests)". Suggestion, never a downgrade. */
  assert.match(app, /const GROW_SETUP_CLIMB_V305=\[\s*\r?\n?\s*\['points','Points earned',/);
  assert.match(app, /\['visits','Visits',/);
  // Points earned is listed FIRST and marked as the suggestion — but only for a NEW ladder.
  assert.match(wizard, /const tierBasisStoredW6I2=\['visits','spend','points_earned'\]\.includes\(String\(base\?\.tier_basis\|\|''\)\);/);
  assert.match(wizard, /key==='points'&&!tierBasisStoredW6I2\?'<span class="muted small"><b>Suggested<\/b><\/span>':''/);
  // A stored basis round-trips to itself — the amendment's "never silently downgrade".
  assert.match(wizard, /if\(v==='points_earned'\)return 'points';/);
  assert.match(wizard, /if\(v==='spend'\)return 'spend';/);
  assert.match(wizard, /if\(v==='visits'\)return 'visits';/);
  assert.match(wizard, /tierBasis:tierBasisFromDbV306\(base\?\.tier_basis\),/);
  // The Climbing screen is screen 1 of EVERY tier rail now, not only a tiers-only one.
  assert.match(app, /\['tiers',\[\['climb','Climbing'\],\['tiers','Tiers'\]\]\]/);
  assert.match(wizard, /const climbStepHtmlV305=\(\)=>`<p class="grow-setup-lead-v301">How do customers climb tiers\?<\/p>/);
  /* The plan's silent accrual (points programme accrues=true, customer_visible=false) has NO
     physical representation — public.business_programmes is (id,business_id,kind,active,sort,…)
     and nothing else — so a points-earned ladder with the points programme off is a ladder that
     can never move: no earn row is ever written and the tier metric stays 0 forever. The screen
     used to claim that accrual exists and to collect an earn rate the engine could never apply.
     The dependency is real now, and stated. */
  assert.match(wizard, /const pointsLadderStalledW6I2=\(\)=>state\.switches\.tiers===true&&state\.tierBasis==='points'/);
  assert.match(wizard, /&&state\.switches\.points!==true;/);
  assert.doesNotMatch(wizard, /Points only move the ladder here/);
  assert.doesNotMatch(wizard, /data-grow-setup-climbearn-v305/);
  assert.match(wizard, /Turn on Points &amp; gifts to use this ladder/);
  assert.match(wizard, /id="growSetupTurnOnPointsW6I2"/);
  assert.match(wizard, /The rate customers earn at is set on the Earning screen\./);
  assert.match(wizard, /This ladder counts lifetime spend\./);
  assert.match(wizard, /Tier levels are counted from completed visits, so there is no points rate to set here\./);
  // Next writes tier_basis (and the earn fields) through the SAME draft writer every screen uses.
  assert.match(wizard, /if\(kind==='climb'\)return withBusy\(async\(\)=>\{/);
  assert.match(wizard, /const result=await saveDraft\(programRowV305\(model\)\);/);
  // Selecting a basis only re-renders; nothing is written until Next.
  assert.match(wizard, /state\.tierBasis=button\.dataset\.growSetupBasisV305==='points'\?'points':'visits';/);
  assert.match(wizard, /const tierUnitLabelV303=\(\)=>tierBasisV303\(\)==='visits'\?'Visits to reach it':'Points to reach it';/);
});

test('W6I2 (g) every expiry knob is reachable — owner amendment 2026-08-14', () => {
  /* "every expiry knob survives per-programme — points expiry in all its modes (e.g. yearly via
     expiry_days=365, inactivity)". Before this wave the wizard had NO expiry control: the row it
     wrote carried whatever was already stored, so an owner who only used the wizard could never
     reach the knob. Surviving has to mean reachable. */
  /* V334: Earning + Expiry merged into one rail step (owner markup 2026-08-15 photo 6). */
  assert.match(app, /\['points',\[\['earnExpiry','Earning & expiry'\],\['reward','Gifts'\]\]\]/);
  assert.match(wizard, /const expiryStepHtmlW6I2=\(\)=>\{/);
  // The DB's own three modes, in the deep editor's own words.
  assert.match(wizard, /<option value="none"\$\{state\.expiryMode==='none'\?' selected':''\}>Never expire<\/option>/);
  assert.match(wizard, /Fixed shelf life from earn \(oldest expire first\)/);
  assert.match(wizard, /Expire after inactivity \(clock resets on every earn\)/);
  // Yearly is fixed + 365, exactly as the amendment spells it — not a fourth mode.
  assert.match(wizard, /else if\(preset==='year'\)\{state\.expiryMode='fixed';state\.expiryDays=365\}/);
  assert.match(wizard, /One year \(365 days\)/);
  assert.match(wizard, /After 365 quiet days/);
  // The days field follows the SAME helper the deep editor's lx/lxd pair follows.
  assert.match(wizard, /const needsDays=expiryModeRequiresDays\(state\.expiryMode\);/);
  assert.match(wizard, /if\(expiryModeRequiresDays\(state\.expiryMode\)&&!\(Number\(state\.expiryDays\)>0\)\)\{/);
  // Rung-level windows keep their home, and the screen says where that is.
  /* V364: both sentences kept their meaning and dropped the name of a control that no longer
     exists — pointing an owner at "More reward settings" would now point at nothing. */
  assert.match(wizard, /Rung start and end dates stay in the full rewards editor\./);
  assert.match(wizard, /each rung's start and end dates live in the full rewards editor\./);
});

test('W6I2 (g) D3: a threshold or basis change states the movement and requires a tick', () => {
  /* Plan decision D3: "raising a tier threshold re-evaluates members immediately; the publish
     preview must state 'N members would move down' and require explicit confirmation."
     WHAT changes is computed from data the screen already holds (published liveTiers vs the draft
     ladder), so the confirmation gate never depends on a server that may not answer. */
  assert.match(wizard, /const publishedTiersW6I2=\(\)=>\(Array\.isArray\(liveTiers\)\?liveTiers:\[\]\)/);
  assert.match(wizard, /const tierThresholdChangesW6I2=\(\)=>\{/);
  assert.match(wizard, /direction:draft\.threshold>live\.threshold\?'harder':'easier'/);
  /* And the basis half compares the draft against the PUBLISHED basis, so it survives leaving the
     wizard and coming back — exactly like the threshold half above. */
  assert.match(wizard, /const tierBasisChangedW6I2=\(\)=>publishedTierBasisW6I2!==null&&state\.tierBasis!==publishedTierBasisW6I2;/);
  // Only a change that can move someone DOWN needs the tick. Easier thresholds move people up.
  assert.match(wizard, /&&\(tierBasisChangedW6I2\(\)\|\|tierThresholdChangesW6I2\(\)\.some\(change=>change\.direction!=='easier'\)\);/);
  assert.match(wizard, /id="growSetupTierAckW6I2"/);
  assert.match(wizard, /I understand members can move down a tier when I publish\./);
  /* HOW MANY move is a per-client aggregation the browser cannot do, so it is read from
     preview_publish_impact behind a CAPABILITY CHECK. The key does not exist on the server yet;
     an absent key must print an honest sentence, never a zero it cannot stand behind. */
  assert.match(wizard, /const tierMovementCountsW6I2=\(\)=>\{/);
  assert.match(wizard, /if\(!movements\|\|typeof movements!=='object'\)return null;/);
  assert.match(wizard, /if\(movements\.evaluated===false\)return \{evaluated:false,reason:String\(movements\.reason\|\|''\)\};/);
  assert.match(wizard, /How many members move is not counted yet on this workspace/);
  assert.match(wizard, /There are too many members to count the moves before publishing\./);
  // The preview is read when the gate PAINTS, not only when Publish is pressed.
  const load = wizard.slice(wizard.indexOf('async function loadComparison(){'), wizard.indexOf('const readStepFields='));
  assert.match(load, /sb\.rpc\('preview_publish_impact',\{p_config_version_id:state\.versionId\}\)/);
  assert.match(load, /state\.impact=impact;/);
  // And it is fail-soft in both directions: a failed read leaves the honest sentence, not a crash.
  assert.match(load, /\.then\(response=>response\.error\?null:\(response\.data\|\|null\)\)\.catch\(\(\)=>null\)/);
});

test('W6I2 (g) the Go-live summary names every switched-on programme, and the switch set', () => {
  /* One line could stand for a programme when there was one. With four independent switches a
     single line simply omits three of them, so the summary is composed the same way the rail is. */
  assert.match(wizard, /if\(state\.switches\.stamps===true\)parts\.push\(/);
  assert.match(wizard, /if\(state\.switches\.points===true\)parts\.push\(/);
  assert.match(wizard, /if\(state\.switches\.referral===true\)parts\.push\(referralExampleTextW6I2\(\)\);/);
  assert.match(wizard, /return parts\.length\?parts\.join\(' · '\):'No programme is turned on\.';/);
  /* The four flags are restated on the gate — they are the one live thing publish changes.
     V322 (OWNER RULING R6): the summary now reads the PAYLOAD, not the scope, because after the
     ruling those are no longer the same thing. It used to print `const on=state.switches[kind]===
     true&&!state.keepPaused;` and then "ON"/"off" per kind — which said "off" beside a programme
     the publish does not touch at all, i.e. the screen asserting exactly the thing the ruling
     forbids. Four honest states now, read off the payload: `turning ON` for a selected kind,
     `staying paused` for a selected kind under keep-it-paused, `switching OFF` only for the
     exclusivity the owner already confirmed, and `left as it is` for a kind that is not sent.
     The claim survives and gets stronger: the gate states what THIS publish does to every one of
     the four programmes, including "nothing". */
  assert.match(wizard, /const switchSummaryBlockW6I2=\(\)=>\{/);
  assert.match(wizard, /const payload=programmeScopeSwitchesV322\(state\.switches,\{paused:state\.keepPaused===true\}\)\|\|\{\};/);
  assert.match(wizard, /<div class="imp-note" data-grow-setup-switchsummary-w6i2/);
  assert.match(wizard, /const sent=Object\.prototype\.hasOwnProperty\.call\(payload,kind\);/);
  assert.match(wizard, /const state322=!sent\?'left as it is'\s*\r?\n?\s*:payload\[kind\]===true\?'turning ON'\s*\r?\n?\s*:state\.switches\[kind\]===true\?'staying paused'\s*\r?\n?\s*:'switching OFF';/);
  assert.match(wizard, /data-grow-setup-switchsummary-state-v322="\$\{esc\(state322\)\}"/);
  assert.match(wizard, /data-grow-setup-switchsummary-kind-w6i2="\$\{esc\(kind\)\}"/);
  // The retired reading — scope treated as an on/off decision — must not come back.
  assert.doesNotMatch(wizard, /const on=state\.switches\[kind\]===true&&!state\.keepPaused;/);
  // The tiers-only claim line survives, keyed on the switches rather than on a model name.
  assert.match(wizard, /const tiersOnlyClaimLineV305=\(\)=>!\(state\.switches\.tiers===true&&state\.switches\.points!==true&&state\.switches\.stamps!==true\)\?''/);
  assert.match(wizard, /While Tier membership runs on its own, customers cannot claim point gifts\./);
  assert.match(wizard, /data-grow-setup-claimline-v305/);
  /* The whole switchboard is built from classes the page ALREADY ships — no new CSS, which is
     what keeps nine checked-in browser fixtures (they inline this stylesheet under a
     production-source-sha256 and carry captured Chrome measurements) from all needing a recapture
     for a cosmetic rule. */
  assert.match(html, /\.grow-setup-options-v301\{display:grid/);
  assert.match(html, /\.pill\.on\{/);
  assert.match(html, /\.grow-setup-basisopt-v305\{[^}]*min-height:44px/);
});

test('V305 (g) the Go-live change list cannot contradict the integrity promise', () => {
  /* Found while pinning the tiers-only walk. A draft carries only the reward versions it has been
     made to carry — create_loyalty_config_draft copies the programme row and the tiers, never the
     rewards — and publish_loyalty_config UPDATEs from those versions, leaving untouched rows
     alone. growRewardPendingChangesV291 does not know that: it puts anything live and absent from
     the draft into `removed`. So a tiers-only draft over a live catalogue printed "Free flat white
     — no longer offered" for every reward, directly beneath a line promising they stay saved. Two
     statements, one screen, opposite meanings — and the wrong one was the scarier one.
     The comparison is now scoped to the rewards the draft actually carries, which is precisely the
     set publishing can change. An archived reward is still reported, because the draft carries
     that version: it appears as "Offered: Yes → No" rather than vanishing. */
  assert.match(comparison, /const draftRewardIdsV305=new Set\(\(Array\.isArray\(draftResult\?\.data\?\.rewards\)\?draftResult\.data\.rewards:\[\]\)\s*\r?\n?\s*\.map\(reward=>String\(reward\.reward_id\|\|reward\.id\|\|''\)\)\.filter\(Boolean\)\);/);
  assert.match(comparison, /liveRewards:growAttachEligibilityV291\(\s*\r?\n?\s*pseudoSnapshot\.rewards\.filter\(reward=>draftRewardIdsV305\.has\(String\(reward\.id\|\|''\)\)\),\s*\r?\n?\s*pseudoSnapshot\.rewardEligibility\),/);
  // The archive path is a FIELD change, so scoping the live side cannot hide a real removal.
  assert.match(app, /\{label:'Offered',read:reward=>reward\.active!==false,show:value=>value\?'Yes':'No'\},/);
  // The name lookups still see the whole catalogue — only the diff's live side is narrowed.
  assert.match(comparison, /options:growRewardDiffOptionsFromSnapshotV291\(pseudoSnapshot,unit\)\}\),/);
});

test('W6I2 (g) turning a programme on NEVER deletes: the wizard writes through an exact allowlist', () => {
  /* Owner: "you need to ensure programs integrity". The strongest form of that promise is that
     there is nothing in this surface that COULD destroy a reward, a tier or an earn rule. Every
     data call the wizard makes is enumerated here; a new one has to be added deliberately, with a
     reason, rather than arriving unnoticed inside a screen. */
  const rpcNames = [...new Set([...wizard.matchAll(/sb\.rpc\('([a-z0-9_]+)'/g)].map(m => m[1]))].sort();
  assert.deepEqual(rpcNames, [
    'create_loyalty_config_draft',        // the draft, created on the first save only
    'ensure_published_reward_in_draft_v138', // materialise-before-edit, never a delete
    'get_loyalty_reward_draft',           // read-back
    'preview_publish_impact',             // read-only gate, and D3's movement counts
    'publish_loyalty_config',             // the publish itself
    'save_loyalty_config_draft',          // programme row / tier_basis / expiry / reward envelope
    'save_loyalty_tier_draft_v143',       // one tier row at a time
    /* V322 (OWNER RULING R1/R4 — "why referral is a stored credits? please remove it as i already
       said no more store credits"): the referral payout stopped being money, so its writer got a
       new name and a new argument (p_reward_points, an integer count of points, replacing
       p_reward_cents). Renaming rather than re-purposing is the point: the pre-v322 money
       signature stays installed for the cached bundle's window, and a stale bundle calling the old
       name cannot accidentally be read as paying points. The allowlist's own claim — every data
       call the wizard makes is enumerated, and none of them can destroy a row — is unchanged. */
    'save_referral_program_v322'          // W6I2: the referral rail, applied at Go-live only
  ].sort(), `wizard RPC allowlist drifted: ${JSON.stringify(rpcNames)}`);
  /* save_referral_program_v322 is the ONE live-table write the wizard performs besides the spine,
     and it is deliberately not a draft write: public.referral_programs is not versioned. It runs at
     Go-live, beside the switches, never on a screen's Next — otherwise a setup the owner walks
     away from would have turned referrals on for real. */
  const referralWrites = [...wizard.matchAll(/sb\.rpc\('save_referral_program_v322'/g)].length;
  assert.equal(referralWrites, 1, 'exactly one referral write');
  // The retired money signature is not called from the wizard at all.
  assert.doesNotMatch(wizard, /sb\.rpc\('save_referral_program'/);
  assert.doesNotMatch(wizard, /p_reward_cents/);
  const switchApply = wizard.slice(wizard.indexOf('async function applyProgrammeSwitchesV314(fromRetry){'),
    wizard.indexOf('const programRowV305=model=>{'));
  assert.match(switchApply, /sb\.rpc\('save_referral_program_v322'/, 'and it lives inside the Go-live switch application');
  /* V322 (OWNER RULING R6): and it is reached only when referral is IN SCOPE. The spine payload no
     longer names a programme the owner did not select, so its companion write must not either — a
     run that never went near the referral screens leaves referral_programs exactly as it found it. */
  assert.match(switchApply, /if\(state\.switches\.referral!==true\)\{state\.modeError='';if\(fromRetry\)render\(\);return true\}/);
  const referralBranch = wizard.slice(wizard.indexOf("if(kind==='referral')return withBusy"),
    wizard.indexOf("if(kind==='reward'||kind==='stampGift')return withBusy"));
  assert.ok(referralBranch.length > 80, 'the referral branch was found and sliced');
  assert.doesNotMatch(referralBranch, /sb\.rpc|sb\.from/);
  assert.equal([...wizard.matchAll(/writeProgrammeSwitchesV314\(/g)].length, 1,
    'the wizard reaches the spine through exactly one call to the shared writer');
  /* ZERO direct table writes. The businesses.points_mode update was the last one, and it became
     an owner-gated RPC whose only effect is four boolean flags on public.business_programmes —
     still a switch, still never a row deletion. */
  const tableWrites = [...new Set([...wizard.matchAll(/sb\.from\('([a-z_]+)'\)\.([a-z]+)\(/g)]
    .map(m => `${m[1]}.${m[2]}`))].sort();
  assert.deepEqual(tableWrites, [], `wizard table access drifted: ${JSON.stringify(tableWrites)}`);
  // No delete, in any spelling, anywhere in the wizard.
  assert.doesNotMatch(wizard, /\.delete\(\)/);
  assert.doesNotMatch(wizard, /sb\.rpc\('[a-z0-9_]*(delete|remove|archive|purge)[a-z0-9_]*'/);
  /* Removal is an ARCHIVE write through the same save helper — active:false, with Undo writing
     active:true back — so even the owner-facing "Remove" cannot destroy a row. */
  assert.match(wizard, /const result=await runSaveV304\(\(\)=>saveRewardFormV304\(\{id:reward\.id,name:reward\.name,\s*\r?\n?\s*budget:\(reward\.budgetCents\/100\)\.toFixed\(2\),points:String\(reward\.points\)\},\{active:false\}\)\);/);
  assert.match(wizard, /\{active:true\}\)\);/);
});

/* ---------------- housekeeping ---------------- */

test('V301 the wizard styles ship with the page and hold at 390px', () => {
  assert.match(html, /\.grow-setup-v301\{/);
  assert.match(html, /\.grow-setup-options-v301\{display:grid;grid-template-columns:repeat\(auto-fit,minmax\(200px,1fr\)\)/);
  assert.match(html, /\.grow-setup-input-v301\{[^}]*min-height:44px/);
  assert.match(html, /@media \(max-width:520px\)\{\s*\r?\n?\s*\.grow-setup-v301\{padding:4px 10px 16px\}/);
});
