/* V323 — the customer's stamp card is a QUEST, and claiming a milestone does not reset it.
 *
 * BEHAVIOURAL, not source regexes. The repo has already paid for the alternative twice: nineteen
 * source-level pins stayed green through five confirmed-broken defects (W6I2), and a grep that
 * matches the line it was written against still matches when that line's surroundings make it
 * meaningless. So every rule below LIFTS THE REAL FUNCTION out of app/app.js, gives it real input,
 * and asserts on the markup it actually produces.
 *
 * What this file guards, in the owner's own terms:
 *   "stamps is like a quest … 3 stamp = xx rewards, 5 stamp = xx rewards, 8 stamp = xx rewards …
 *    Milestones are non-consuming: reaching 5 does not reset progress toward 8."
 *
 *   1. The card shows filled/total against the CURRENT cycle — never the lifetime figure.
 *   2. It says which milestones are already collected ON THIS CARD, which is next, and how far.
 *   3. It NEVER prints a points figure. A v322-era defect was a stamp card printing "points".
 *   4. Carried stamps past the end of the card are said out loud, not absorbed silently.
 *   5. The loader degrades to the shipped v310 card on every failure path, in both directions of
 *      the four-hour CDN window.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const topLevel = (name, endMarker) => {
  const start = app.search(new RegExp(`^(?:const|function) ${name}\\b`, 'm'));
  assert.ok(start >= 0, `missing top-level declaration: ${name}`);
  const end = app.indexOf(endMarker, start);
  assert.ok(end > start, `missing end marker for ${name}: ${endMarker}`);
  return app.slice(start, end);
};
const closure = (head, endMarker) => {
  const start = app.indexOf(head);
  assert.ok(start >= 0, `missing closure: ${head}`);
  const end = app.indexOf(endMarker, start);
  assert.ok(end > start, `missing end marker for ${head}: ${endMarker}`);
  return app.slice(start, end);
};

const esc = value => String(value ?? '').replace(/[&<>"]/g, ch =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]));

/* The four English sentences the card can say, lifted from app/app.js's own en dictionary rather
   than restated here — a copy would be a second implementation that cannot go stale together. */
const EN = {};
for (const [, key, value] of app.matchAll(
  /^\s{4}(stampsQuest[A-Za-z]+|stampsNoGift|stampsRemaining|stampsReady|rewardsTab):'([^']*)',$/gm
)) {
  /* FIRST occurrence only. Every key exists four times — en, zh-CN, ms, ta, in that order — and a
     plain Object.fromEntries would silently hand this file the Tamil dictionary. */
  if (!(key in EN)) EN[key] = value;
}
const ct = (key, vars = {}) => String(EN[key] ?? key)
  .replace(/\{(\w+)\}/g, (whole, name) => (name in vars ? String(vars[name]) : whole));

const questSrc =
  topLevel('stampQuestNormaliseV323', 'function customerStampQuestRingsV323') +
  topLevel('customerStampQuestRingsV323', 'function customerStampQuestBodyV323') +
  topLevel('customerStampQuestBodyV323', '/* 2 · POINTS & GIFTS');
const quest = new Function('esc', 'ct', 'customerPointTotalV103', 'PROGRAMME_STACK_RING_LIMIT_V310',
  `${questSrc}\nreturn {stampQuestNormaliseV323,customerStampQuestRingsV323,customerStampQuestBodyV323};`
)(esc, ct, value => String(value), 24);

/* The owner's own example: a 3 / 5 / 8 quest on an 8-stamp card. The customer is mid-quest on their
   SECOND card, holding 4 of 8, and has already collected the 3-stamp gift on this card. Four is
   chosen deliberately: it is PAST the collected rung and SHORT of the next one, which is the only
   position where "did collecting the 3-stamp gift push the 5-stamp gift away?" is answerable. */
const payload = ({ slots = 8, filled = 4, cycle = 1, claimed = [3], carried = 0 } = {}) => ({
  enabled: true,
  contract: 'v323',
  unit: 'stamps',
  running: true,
  slots,
  filled: filled + carried,
  cycle_index: cycle,
  lifetime: 22,
  ready: filled + carried >= slots,
  pot_migrated: false,
  milestones: [
    { reward_id: 'r8', name: 'Free haircut', slot: 8, is_final: true },
    { reward_id: 'r3', name: 'Free drink', slot: 3, is_final: false },
    { reward_id: 'r5', name: 'A pastry', slot: 5, is_final: false }
  ].map(rung => ({
    ...rung,
    claimed_this_cycle: claimed.includes(rung.slot),
    availability: claimed.includes(rung.slot) ? 'claimed_this_cycle'
      : (filled + carried) >= rung.slot ? 'available_at_counter' : 'insufficient_stamps',
    stamps_to_go: Math.max(rung.slot - (filled + carried), 0)
  }))
});

const rungs = markup => [...markup.matchAll(
  /data-stamp-quest-rung-v323="(\d+)" data-stamp-quest-rung-claimed-v323="(yes|no)"/g
)].map(([, slot, claimed]) => [Number(slot), claimed === 'yes']);
const line = (markup, name) => markup.match(
  new RegExp(`data-stamp-quest-line-v323="${name}">([^<]*)<`))?.[1] ?? null;

/* ==============================================================================================
 * THE RULING
 * ============================================================================================ */

test('V323 the card shows the CURRENT cycle, its ladder, and what is already collected on it', () => {
  const markup = quest.customerStampQuestBodyV323(quest.stampQuestNormaliseV323(payload()));

  assert.deepEqual(rungs(markup), [[3, true], [5, false], [8, false]],
    'the ladder renders in stamp order and marks only what was collected on THIS card');
  assert.match(markup, /data-stamp-quest-list-v323="3"/,
    'the milestone count is unbounded and comes from the payload, not from three fixed slots');
  assert.equal(line(markup, 'progress'), '4 of 8 stamps on this card.');
  assert.equal(line(markup, 'next'), '1 more stamps and your next A pastry is on us.',
    'the next rung is the lowest UNCOLLECTED one, and the distance is measured from the card');
});

test('V323 collecting a milestone does not move the next one — the whole ruling, measured', () => {
  /* The defect this closes: claiming the 3-stamp gift used to DRAIN three stamps, so a customer at
     4 who accepted the drink dropped to 1 and went from "1 more for the pastry" to "4 more" by
     saying yes to a present. Both cards below hold the same four stamps; the only difference is
     whether slot 3 has been collected. */
  const before = quest.customerStampQuestBodyV323(
    quest.stampQuestNormaliseV323(payload({ claimed: [] })));
  const after = quest.customerStampQuestBodyV323(
    quest.stampQuestNormaliseV323(payload({ claimed: [3] })));

  assert.equal(line(before, 'progress'), line(after, 'progress'),
    'collecting a milestone must not move the card');
  assert.match(line(before, 'next'), /Free drink/, 'before: the 3-stamp gift is the next one');
  assert.match(line(after, 'next'), /A pastry/, 'after: the ladder advanced to the 5-stamp gift');
  assert.equal(line(after, 'next'), '1 more stamps and your next A pastry is on us.',
    'and the 5-stamp gift is one stamp away — 5 minus the 4 on the card. Under the old, consuming\n     claim the three stamps would have gone with the drink and this would read four.');
  assert.equal(
    quest.stampQuestNormaliseV323(payload({ claimed: [] })).filled,
    quest.stampQuestNormaliseV323(payload({ claimed: [3] })).filled,
    'and the card itself holds the same stamps either way');
});

test('V323 the rings draw the current card, marking every milestone and every collected slot', () => {
  const markup = quest.customerStampQuestRingsV323(quest.stampQuestNormaliseV323(payload()));
  const slots = [...markup.matchAll(/data-stamp-quest-slot-v323="(\d+)"/g)].map(m => Number(m[1]));
  assert.deepEqual(slots, [1, 2, 3, 4, 5, 6, 7, 8], 'one ring per slot on the CURRENT card');
  assert.equal((markup.match(/is-filled/g) || []).length, 4, 'four of eight collected');
  assert.equal((markup.match(/is-goal/g) || []).length, 3,
    'every milestone is marked, not just the last one');
  assert.match(markup, /data-stamp-quest-rings-v323="4\/8"/);
  assert.match(markup, /aria-label="4 of 8 stamps on this card\."/,
    'the single aria-label carries the whole fact; the rings are decorative to a screen reader');
  /* No new CSS rule: seven browser fixtures inline app/index.html's stylesheet under captured
     Chrome measurements pinned to a production-source-sha256. */
  const classes = new Set([...markup.matchAll(/class="([^"]+)"/g)]
    .flatMap(m => m[1].split(/\s+/)));
  assert.deepEqual([...classes].sort(),
    ['customer-programme-stamp-ring', 'customer-programme-stamp-rings', 'is-filled', 'is-goal']);
});

test('V323 stamps past the end of the card are CARRIED and said out loud', () => {
  const markup = quest.customerStampQuestBodyV323(
    quest.stampQuestNormaliseV323(payload({ filled: 8, carried: 2, claimed: [3, 5] })));
  assert.equal(line(markup, 'progress'), '8 of 8 stamps on this card.',
    'the card never shows more than its own length');
  assert.equal(line(markup, 'carried'), '2 already counted toward your next card.');
  assert.equal(line(markup, 'next'), ct('stampsReady', { gift: 'Free haircut' }),
    'a full card names the gift that finishes the quest');
});

test('V323 the stamp card never prints a points figure', () => {
  /* The v322-era defect. The figure a stamp card used to reach for came from
     app.c45_base_actionable_wallet_card, whose balance CTEs carry no programme filter at all, so at
     a firm holding two pots the stamp card and the points card printed the same number. */
  const markup = quest.customerStampQuestBodyV323(quest.stampQuestNormaliseV323(payload()));
  assert.doesNotMatch(markup, /points/i);
  assert.doesNotMatch(questSrc.replace(/\/\*[\s\S]*?\*\//g, ''), /loyalty\.balance|c45_base_actionable/);
  /* And the normaliser physically cannot read one: a payload carrying a balance key is ignored. */
  const withBalance = quest.stampQuestNormaliseV323({ ...payload(), balance: 4321, points: 4321 });
  assert.doesNotMatch(JSON.stringify(withBalance), /4321/);
});

test('V323 every rung the card can be in has an honest line', () => {
  const allCollected = quest.customerStampQuestBodyV323(
    quest.stampQuestNormaliseV323(payload({ filled: 8, claimed: [3, 5, 8] })));
  assert.equal(line(allCollected, 'next'), ct('stampsQuestAllClaimed'));

  /* nestly_v422 (owner photo 6, the sentence struck out: "remove this wording"). A migrated pot
     used to render ONE sentence here — "This stamp card has been retired — ask us about your
     balance." The owner's ruling is that the box goes with the sentence, the same rule v326/v386
     already apply to a paused programme, so loadStampCardV323 removes the whole card before this
     body is ever built and there is no retired branch left. Asserted in the loader test below. */
  assert.doesNotMatch(app, /stampsQuestRetired/, 'the sentence and its four locale strings are gone');

  /* An unconfigured card (stamp_target NULL) must never invent a length. The rule W4b wrote down:
     a default of 10 would be a number the business never chose, printed with the authority of a
     picture. */
  const unset = quest.customerStampQuestBodyV323(
    quest.stampQuestNormaliseV323({ ...payload({ slots: 0 }), slots: null }));
  assert.doesNotMatch(unset, /data-stamp-quest-rings-v323/);
  assert.match(unset, /data-stamp-quest-count-v323="4"/);
  assert.equal(line(unset, 'progress'), ct('stampsNoGift', { count: 4 }));
});

/* ==============================================================================================
 * THE CONTRACT BOUNDARY — both directions of the CDN window
 * ============================================================================================ */

test('V323 anything that is not a v323 card leaves the shipped v310 card standing', () => {
  for (const payloadThatMustNotRender of [
    null, undefined, {}, { enabled: false },
    { enabled: true },                                    // an older reader, no contract key
    { enabled: true, contract: 'v321' },                  // a contract this bundle does not speak
    { enabled: false, contract: 'v323', slots: 8 }
  ]) {
    assert.equal(quest.stampQuestNormaliseV323(payloadThatMustNotRender), null,
      `${JSON.stringify(payloadThatMustNotRender)} must not be rendered as a quest`);
  }
});

test('V323 the loader replaces the v310 card only on a clean answer, and never blanks it', () => {
  const src = closure('const loadStampCardV323=async()=>', 'const loadGrowthOffers=async()=>');
  /* Read as a sequence of guards, each of which must return BEFORE anything is removed from the
     DOM. The order is the property: every early return happens above the first mutation.
     nestly_v422: this loader serves TWO surfaces now — the stamps card, and the business-profile
     hero (owner photo 8) — so the tokens below name the CARD's own mutations specifically. The
     hero's insertion is a different node on a different screen and is guarded on its own line. */
  const at = token => { const i = src.indexOf(token); return i < 0 ? Infinity : i; };
  const anyCardMutation = Math.min(at('line.insertAdjacentHTML'), at('figure.remove()'),
    at('line.remove()'), at('card.remove()'));
  const replaceMutation = Math.min(at('line.insertAdjacentHTML'), at('figure.remove()'),
    at('line.remove()'));
  assert.ok(Number.isFinite(anyCardMutation), 'the loader must mutate the card at some point');

  for (const guard of [
    'if(!card&&!heroSlotV422&&!pointsCardV435)return;', /* nestly_v435: the kept-note also fires this read in points mode */     // neither surface this read serves is on the page
    'if(error)return;',                    // an old server behind a new bundle: no such RPC
    'if(!card||!card.isConnected)return;', // the hero was served; there is no stamps CARD to edit
    'if(!quest||!quest.running)return;'    // no card, a foreign contract, or a PAUSED programme
  ]) {
    assert.ok(at(guard) >= 0, `missing guard: ${guard}`);
    assert.ok(at(guard) < anyCardMutation,
      `guard "${guard}" runs after the card has already been touched`);
  }
  /* The v310 card is in a shape this cannot safely edit — guards the REPLACE path. It sits below
     the pot-migrated branch, which is a terminal `card.remove()` + `return` and needs no line. */
  assert.ok(at('if(!line)return;') >= 0 && at('if(!line)return;') < replaceMutation,
    'the replace path still refuses a card whose sentence it cannot find');

  /* nestly_v422 (owner photo 6, "remove this wording"): a migrated pot takes the whole card, not
     just its sentence — and #walletRewards is lifted out first, because the stamps card HOSTS the
     reward list whenever stamps is the live accruing programme. */
  const migrated = src.slice(src.indexOf('if(quest.potMigrated){'));
  assert.ok(migrated.indexOf("card.querySelector('#walletRewards')") <
    migrated.indexOf('card.remove()'),
    'the reward list is moved out before the card it lives in is removed');
  assert.match(migrated, /insertAdjacentElement\('beforebegin',rewardsHostV422\)/);

  assert.ok(at('if(!isWalletCurrent())return;') < anyCardMutation,
    'a wallet the customer has already navigated away from must not be written to');
  assert.match(src, /if\(heroSlotV422&&heroSlotV422\.isConnected&&quest&&quest\.running\)/,
    'and the hero is only written while its own node is still on the page');
  /* It is fetched beside the other wallet loaders, not on a second render pass. */
  assert.match(app, /await Promise\.all\(\[loadMemberCodeW6I2\(\),loadReferralCardV300\(\),loadStampCardV323\(\),/);
});

test('V323 the four remaining customer sentences exist in all four locales', () => {
  /* tests/customer-wallet/v293-customer-wallet-localization.test.mjs turns red on a missing key;
     this asserts the same thing at the point the keys were added, and that none of the four
     translations was left as the English string. */
  /* nestly_v422 removed stampsQuestRetired from all four locales with the sentence it served. */
  const keys = ['stampsQuestProgress', 'stampsQuestCarried', 'stampsQuestClaimed',
    'stampsQuestAllClaimed'];
  for (const key of keys) {
    const values = [...app.matchAll(new RegExp(`^\\s{4}${key}:'([^']*)',$`, 'gm'))]
      .map(match => match[1]);
    assert.equal(values.length, 4, `${key} must exist in all four customer locales`);
    assert.equal(new Set(values).size, 4, `${key} has an untranslated locale`);
  }
  /* The placeholders have to survive translation or the sentence prints a literal {filled}. */
  const progress = [...app.matchAll(/^\s{4}stampsQuestProgress:'([^']*)',$/gm)].map(m => m[1]);
  for (const value of progress) {
    assert.match(value, /\{filled\}/);
    assert.match(value, /\{total\}/);
  }
});
