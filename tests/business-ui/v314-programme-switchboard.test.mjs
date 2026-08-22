/* V314 (W6 increment 1) — THE CLIENT HALF OF THE SWITCHBOARD INVERSION.
 *
 * v314 makes public.business_programmes the authority on which programmes run: the four v308 sync
 * triggers are dropped, public.set_programmes_v314 becomes the only writer, and
 * businesses.points_mode is frozen behind a tripwire that silently PINS any write and records
 * POINTS_MODE_WRITE_SUPPRESSED_V314. Silently is the whole problem: PostgREST answers 204 with no
 * error, so a browser that still writes that column reports success, flips its own local state and
 * re-renders as though the owner's choice had reached the engine.
 *
 * An adversarial review of the first cut found three ways the owner's ON/OFF decision failed to
 * arrive. All three were CLIENT defects, invisible to the SQL suite, and this file is what makes
 * them stay fixed:
 *
 *   1. TWO SURVIVING points_mode WRITERS. The Grow editor's Save (the four-way
 *      data-loyalty-model-v235 toggle) and the [data-points-mode-v229] chooser both still did
 *      `sb.from('businesses').update({points_mode:…})`. Both became success-reporting no-ops. The
 *      chooser was worse than useless: it renders only when points_mode is falsy, and every tenant
 *      created after v314 is permanently that firm, so the one surface that looked like the place
 *      to choose a model was the one surface that could not.
 *
 *   2. PAUSE WAS TWO TRUTHS. The wizard wrote `active:!keepPaused` onto the draft and then applied
 *      the switches ON regardless, while consumer 1 had just removed loyalty_programs.active from
 *      the earn gate — so "Keep it paused for now — customers earn nothing" published a firm that
 *      earned. PAUSED = the programme's spine row is OFF, and that one flag governs accrual and
 *      payout together.
 *
 *   3. ONE PUBLISH ROUTE OF THREE. Only the setup wizard applied the switches. An owner who set the
 *      programme up in the Grow editor and published from the review page went live with all four
 *      spine rows false: the page said Live and the next sale earned nothing.
 *
 * These are SOURCE-LEVEL pins because the failures are about which call a route makes, not about
 * what it renders. The server side of the same contract is db/tests/v313_v314_programme_switchboard
 * .sql steps 33-35. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const migration = readFileSync(join(root, 'db', 'migrations',
  '20260814_nestly_v314_programme_switchboard_inversion.sql'), 'utf8');

const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
};
/* Comments name the deleted writers on purpose — that is how a later reader learns why they are
   gone — so every "no such write survives" assertion runs against code with the prose removed. */
const stripComments = source => source
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/^\s*\/\/.*$/gm, '');
const code = stripComments(app);
const wizard = section('async function growSetupWizardV301(', 'function growPublishFieldRowsV170(');
const grow = section('async function growPage(', '/* ---------- Bring-back playbooks');
const reviewPublish = section('async function studioPublishReviewPage(', 'async function studioPage(');
const studioOverview = section('async function studioOverview(', '/* ============================ Stored value');

/* ---------------- 1. the two surviving writers ---------------- */

test('V314 (1) NOTHING in the bundle writes businesses.points_mode any more', () => {
  /* The increment-9 upgrade condition — turn the swallow tripwire into a raise once
     audit_log shows zero POINTS_MODE_WRITE_SUPPRESSED_V314 rows over a full CDN window — is only
     SATISFIABLE if this is true. With either writer shipping, that condition can never be met and
     increment 9's plan is unreachable, which is why it is asserted mechanically. */
  assert.equal([...code.matchAll(/\.update\(\{\s*points_mode/g)].length, 0,
    'a points_mode UPDATE survives in app/app.js');
  /* Scoped to the businesses table on purpose: the CUSTOMER surfaces still receive a points_mode
     KEY from customer_portal_capabilities and customer_get_reward_catalog, and v314 derives that
     key from the spine server-side. Those are reads of a derived value, not writes to the frozen
     column, and forbidding the identifier outright would delete a working contract. */
  const businessWrites = [...code.matchAll(/sb\.from\('businesses'\)\.(update|upsert|insert)\(([\s\S]{0,160}?)\)\./g)]
    .filter(match => /points_mode/.test(match[2])).map(match => match[0]);
  assert.deepEqual(businessWrites, [], `a businesses write still carries points_mode: ${JSON.stringify(businessWrites)}`);
  // Nor may anything flip the frozen column in local state and call that a refresh.
  assert.doesNotMatch(code, /S\.biz\.points_mode\s*=[^=]/);
});

test('V314 (1) the [data-points-mode-v229] chooser is gone, markup AND wiring together', () => {
  /* A live listener for a selector nothing renders is how a dead writer comes back. Both halves
     are asserted, in both directions. */
  assert.doesNotMatch(code, /data-points-mode-v229/);
  assert.doesNotMatch(code, /dataset\.pointsModeV229/);
  assert.doesNotMatch(code, /points-mode-card-v229/);
  /* The slot keeps an honest line rather than becoming a blank region, and it points at the
     surface that CAN make the choice — the capability moved, it was not removed. */
  assert.match(grow, /No points programme is set up yet/);
  assert.match(grow, /href="#\/grow\/setup"/);
});

test('V314 (1) the Grow editor Save routes the four-way toggle through the spine', () => {
  const editor = section("const loyaltySave=$('lsave');", "const loyaltyReviewPublish=$('loyaltyReviewPublish');");
  // The selection the toggle produces goes straight into the shared mapping — including 'stamps',
  // which V230 had to flatten into 'redeem' because points_mode had no value for a stamp card.
  assert.match(editor, /await writeProgrammeSwitchesV314\(S\.biz\.id,loyaltySelectionV230,\s*\r?\n?\s*\{paused:\$\('la'\)\.value!=='true'\}\)/);
  // Failure is reported as failure. The old writer's toast fired whatever the server did.
  assert.match(editor, /if\(!switchResultV314\.ok\)\{/);
  assert.match(editor, /return fail\(switchResultV314\.error\)/);
  /* And the refresh comes from the SERVER's reply, never from an optimistic flip: writeProgramme
     SwitchesV314 stores what set_programmes_v314 returned. */
  assert.match(code, /function rememberProgrammeSpineV314\(programmes\)\{/);
  assert.match(code, /rememberProgrammeSpineV314\(data\?\.programmes\);/);
});

/* ---------------- 2. pause is one flag with one meaning ---------------- */

test('V314 (2) keepPaused reaches the switch call, and turns the whole chosen set OFF', () => {
  assert.match(code, /function programmeSwitchSetV314\(selection,\{paused=false\}=\{\}\)\{/);
  assert.match(code, /set\[kind\]=paused\?false:base\[kind\]===true/);
  /* V322 (OWNER RULING R6 — "if i unselect the program does not mean i want to turn off"): the
     wizard's keepPaused flag no longer rides on writeProgrammeSwitchesV314's own `paused` option;
     it rides INTO the payload, through programmeScopeSwitchesV322, because after the ruling the
     payload only names the kinds the owner actually SELECTED. The claim this test makes is
     unchanged and still the whole point — keep-it-paused turns the whole CHOSEN set OFF — it is
     just that "the chosen set" is now literally the set that is sent, rather than all four kinds
     with the unchosen ones swept along. The writer's own paused flag is therefore false here:
     applying the pause twice would pause kinds the payload had already decided. */
  assert.match(code, /function programmeScopeSwitchesV322\(scope,\{paused=false\}=\{\}\)\{/);
  assert.match(code, /PROGRAMME_KINDS_W6I2\.forEach\(kind=>\{if\(scope&&scope\[kind\]===true\)set\[kind\]=paused!==true\}\);/);
  assert.match(wizard, /programmeScopeSwitchesV322\(state\.switches,\{paused:state\.keepPaused===true\}\),\s*\r?\n?\s*\{paused:false,key:state\.switchKeyV314\}/);
  /* The promise this restores, verbatim from the two surfaces that make it. */
  assert.match(wizard, /Keep it paused for now/);
  assert.match(wizard, /Programme will stay PAUSED — customers earn nothing\./);
  assert.match(reviewPublish, /This will publish PAUSED — customers earn nothing\./);
});

test('V314 (2) the server half: redeem_reward_core stops reading loyalty_programs.active', () => {
  /* Pause has to mean the same thing in both directions or a paused firm accrues a liability its
     customers can never spend — which is exactly what the first cut shipped. */
  assert.match(migration, /select \* into lp from public\.loyalty_programs where business_id=p_business and active limit 1;\$needle\$,/);
  assert.match(migration, /\$needle\$ {2}select \* into lp from public\.loyalty_programs where business_id=p_business limit 1;\$needle\$/);
  // And the migration refuses to finish if that flip did not land.
  assert.match(migration, /position\('where business_id=p_business and active limit 1' in v_def\) <> 0/);
});

/* ---------------- 3. all three publish routes ---------------- */

test('V314 (3) every publish route applies the switches through the same helper', () => {
  /* Three call sites of publish_loyalty_config in the bundle; three switch applications. The
     wizard has its own wrapper because it owns the inline retry state, the other two share
     applyPublishedProgrammeSwitchesV314. */
  /* V364 adds a FOURTH call site: the birthday-gift popup (openBirthdayBenefitEditorV364), which
     saves the way the wizard's own Go-live step does — a fresh draft off the active version, the
     birthday rule written into it, then publish. It applies no programme switch and must not:
     the birthday benefit is not one of the four spine programmes, so there is nothing to switch,
     and the three helper counts below are deliberately unchanged. */
  /* nestly_v415 adds a FIFTH call site, and only one: publishOnSaveV415. The owner ruled that
     Save on the Loyalty page publishes rather than parking a draft (photo 2, the banner ringed),
     and all four writers on that page — configuration, birthday, reward, tier — go through that
     ONE helper rather than each calling the RPC. It applies no programme switch, for the same
     reason the v364 birthday popup does not: these writers change what is IN a programme, never
     which programme is running, so the three helper counts below stay as they were. */
  /* nestly_v429 (A): the v364 birthday popup's route is GONE — its three-call save became one atomic public.business_save_birthday_program_v424, which opens the draft and publishes it server-side, so the browser no longer calls publish_loyalty_config there at all. */
  const publishes = [...code.matchAll(/sb\.rpc\('publish_loyalty_config'/g)].length;
  assert.equal(publishes, 4, `expected the four known publish routes, found ${publishes}`);
  assert.equal([...code.matchAll(/sb\.rpc\('business_save_birthday_program_v424'/g)].length, 1,
    'the birthday popup saves and publishes in exactly one server call');
  assert.equal([...code.matchAll(/await publishOnSaveV415\(/g)].length, 4,
    'four writers on the Loyalty page, one publish helper between them');
  assert.equal([...code.matchAll(/applyPublishedProgrammeSwitchesV314\(/g)].length, 3,
    'the helper is declared once and called by exactly the two non-wizard routes');
  assert.equal([...code.matchAll(/applyProgrammeSwitchesV314\(/g)].length, 3,
    'the wizard wrapper is declared once, called once on publish and once from its retry button');

  // Route 2 — the Grow review page. Its own draft's active flag and model decide the set.
  assert.match(reviewPublish, /const switchV314=await applyPublishedProgrammeSwitchesV314\(\s*\r?\n?\s*\{active:draftProgrammeActiveV258,loyaltyModel:draftProgrammeModelV314\}\)/);
  // Route 3 — Studio. It re-reads the draft, because a rules-only publish carries no programme row.
  assert.match(studioOverview, /const draftForSwitchV314=await sb\.rpc\('get_loyalty_reward_draft',\{p_config_version:draftVersionId\}\)/);
  assert.match(studioOverview, /active:draftForSwitchV314\.data\?\.program\?\.active\?\?null/);
});

test('V314 (3) a draft with no programme row leaves the spine alone', () => {
  /* publish_loyalty_config leaves loyalty_programs untouched when the draft carries no programme
     row, so the switch must be skipped too — otherwise a Studio rules publish would switch a firm
     on or off as a side effect of editing an automation. */
  assert.match(code, /async function applyPublishedProgrammeSwitchesV314\(\{active=null,loyaltyModel=null\}=\{\}\)\{\s*\r?\n?\s*if\(active===null\|\|active===undefined\)return \{ok:true,skipped:true,error:null\};/);
});

test('V314 (3) a failed switch never re-publishes an already-live version', () => {
  /* Both non-wizard routes re-enable their confirm button so the owner can retry, and both guard
     the publish behind a "already done" flag: retrying the switch must not be a second publish. */
  assert.match(reviewPublish, /let growPublishedV314=false;/);
  assert.match(reviewPublish, /growPublishedV314\s*\r?\n?\s*\?\{error:null\}/);
  assert.match(studioOverview, /let studioPublishedV314=false;/);
  assert.match(studioOverview, /studioPublishedV314\s*\r?\n?\s*\?\{error:null\}/);
  assert.match(reviewPublish, /Published\. The programme switch could not be applied/);
  assert.match(studioOverview, /Published\. The programme switch could not be applied/);
});

test('V314 (3) the owner Live/paused pill reads the spine, not the settings column', () => {
  /* loyalty_programs.active is a published SETTING after v314 and the two can legitimately
     disagree in both directions: a brand-new tenant that published active=true with no switch
     thrown earns nothing while the pill says Live, and a firm whose owner switched points on over
     a paused published version earns while the pill says paused. */
  assert.match(code, /function ownerRewardJourneyV122\(\{rewards=\[\],birthday=null,loyalty=null,loyaltyModel=null,asOf=null,programmes=null\}=\{\}\)\{/);
  assert.match(code, /const spineAccruingV314=Array\.isArray\(programmes\)&&programmes\.length/);
  assert.match(code, /const programmeActive=spineAccruingV314===null\?loyalty\?\.active===true:spineAccruingV314;/);
  // growPage hands the cached spine in; the function itself stays pure.
  assert.match(grow, /programmes:programmeSpineRowsV314\(\)/);
  // The Programmes tile status asks the same question.
  assert.match(grow, /const loyaltyLive=Boolean\(\(programmeSpineRunningV314\(\)\?\?\(snapshot\.loyalty\?\.active===true\)\)&&snapshot\.currentVersion\)/);
});

/* ---------------- the cache the reads share ---------------- */

test('V314 the spine is cached once per business and refreshed from the server', () => {
  // Same shape as S.myModules: fetched once in route(), invalidated when the business changes.
  assert.match(code, /programmes:null,programmesBusinessId:null\}/);
  assert.match(code, /if\(programmeSpineRowsV314\(\)===null&&S\.myModules&&S\.myModules\.includes\('loyalty'\)\)\{\s*\r?\n?\s*await refreshProgrammeSpineV314\(\);/);
  /* nestly_v428 (item 3): the select also carries deactivated_at — the never-cleared true->false
     breadcrumb (v308:60-61) — so the Programmes History tab can answer from data instead of a
     hardcoded zero. Still SELECT-only, still one read, one column wider. */
  assert.match(code, /sb\.from\('business_programmes'\)\.select\('id,kind,active,deactivated_at'\)\.eq\('business_id',S\.biz\.id\)/);
  /* Both writers into the cache map through ONE row builder, so the reply to set_programmes_v314
     (which names the same column `paused_since`) and the direct table read cannot disagree. */
  assert.match(code, /const programmeSpineRowV428=row=>\(\{id:row\?\.id\|\|null,kind:row\?\.kind\|\|null,active:row\?\.active===true,\s*\r?\n?\s*deactivatedAt:row\?\.deactivated_at\|\|row\?\.paused_since\|\|null\}\);/);
  /* A cache belonging to another business must never answer for this one — the id is checked on
     every read, not only when it is written. */
  assert.match(code, /S\.programmesBusinessId===S\.biz\.id\s*\r?\n?\s*\?S\.programmes:null/);
  // Fail-soft everywhere: an unreadable spine falls back to the legacy column, never to a guess.
  for (const reader of [/const pointsModeV229=programmePointsModeV314\(\)\|\|S\.biz\.points_mode\|\|null/,
                        /const loyaltyModeV230=loyaltyModeDraftV230\|\|programmePointsModeV314\(\)\|\|S\.biz\.points_mode\|\|'redeem'/,
                        /const livePointsModeV303=String\(programmePointsModeV314\(\)\|\|S\.biz\?\.points_mode\|\|'redeem'\)/]) {
    assert.match(code, reader);
  }
});

test('V314 the browser only ever READS public.business_programmes', () => {
  /* The table is SELECT-only for authenticated (v308:181-195) and set_programmes_v314 is the one
     door. A direct write here would be refused by RLS, but it would also mean the client believed
     it had another way in. */
  const spineAccess = [...code.matchAll(/sb\.from\('business_programmes'\)\.([a-z]+)\(/g)].map(m => m[1]);
  assert.deepEqual([...new Set(spineAccess)], ['select']);
});
