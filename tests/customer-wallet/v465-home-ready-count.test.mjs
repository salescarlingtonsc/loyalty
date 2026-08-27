/* nestly_v465 — owner rulings R1 and R6, 2026-08-23.
 *
 * R1  Home says how many rewards are ready, and the number comes from the server: a per-business
 *     ready_count computed inside app.c45_base_actionable_wallet_card through the v432 availability
 *     core, the same core the customer's own business page counts through. The greeting equals the
 *     SUM of the numbers on the cards.
 * R6  (B-REG-023) The business-page ready pill follows the catalogue, INCLUDING down to zero. Its
 *     painted-text fallback used to re-assert "Reward ready" in exactly the case the catalogue had
 *     just resolved to nothing claimable.
 *
 * The renderers are EXECUTED against fixture cards — the v422 harness pattern in this directory.
 * A grep would stay green while the behaviour behind it was dead (see the source-regex lesson).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(path.join(root, 'app', 'app.js'), 'utf8');

const sectionOf = source => (start, end) => {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start} … ${end}`);
  return source.slice(from, to);
};
const section = sectionOf(app);

const esc = v => String(v ?? '').replace(/[&<>"']/g,
  c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const CUI = {icon: name => `<svg data-icon="${name}"></svg>`};

function buildHarness(source) {
  const cut = sectionOf(source);
  return new Function('esc', 'CUI', `
    ${cut('const CUSTOMER_COPY=Object.freeze({', 'const normalizeCustomerLocale=')}
    let customerLocale='en';
    ${cut('function ct(key,vars={}){', 'function customerMediaUrlV95')}
    ${cut('function customerPointTotalV103(', 'const CUSTOMER_SEEN_OFFERS_KEY_V167')}
    ${/* the reward-ready sentence, the v457 signal and the four v465 payload readers */''}
    ${cut('const customerRewardReadyLineV397=', '/* nestly_v428 (item 6)')}
    ${cut('function customerRewardReadyCountApplyV397(', '/* nestly_v399. The customer-facing words')}
    ${cut('const programmeStackV310=', '/* The server answers presentation with customer_visible')}
    ${cut('function programmeStackCardVisibleV310(', '/* One paused block, used by whichever card is paused.')}
    ${cut('function customerProgrammeCardProgrammesV360(', 'function customerProgrammeTileMarkupV96')}
    ${cut('function customerExpiringRowsV286(', 'function customerHomeOffersMarkupV167')}
    ${/* customerRewardReadyCountV343 through customerHomeSummaryV343 is one contiguous run:
         the card mood, the progress track, the nearest goal and the greeting that reads them. */''}
    ${cut('function customerRewardReadyCountV343(', 'function customerHomeBusinessStatusV345')}
    ${cut('function customerHomeBusinessStatusV345(', '/* nestly_v422 (owner photo 5,')}
    /* Resolved by name so the SAME harness can be built from the pre-v465 source, where the four
       v465 readers simply do not exist — that is what the negative controls below assert. */
    const exported = {};
    for (const name of ['customerCardReadyCountV465','customerCardReadyChooseOneV465',
      'customerCardRewardReadyV465','customerRewardReadyTotalV465','customerRewardReadyCountV343',
      'customerHomeSummaryV343','customerHomeBusinessStatusV345','customerCardMoodV2B',
      'customerCardProgressV2B','customerNearestGoalV2B','customerRewardReadyCountApplyV397',
      'customerRewardReadyLineV397','customerRewardReadySignalV457']) {
      try { exported[name] = eval(name); } catch (error) { exported[name] = undefined; }
    }
    return exported;`)(esc, CUI);
}
const H = buildHarness(app);

/* A wallet card in the shape app.c45_base_actionable_wallet_card sends it. `ready` is omitted
   rather than set to null when the fixture is a PRE-v465 server. */
const card = ({name = 'Kopi Lab', ready, chooseOne, availableNow = false, remaining = 0,
  balance = 0, unit = 'stamps'} = {}) => {
  const value = {
    business: {name, slug: name.toLowerCase().replace(/\W+/g, '-')},
    loyalty: {enabled: true, unit, model: unit, balance},
    credit: {balance_cents: 0},
    packages: {sessions_remaining: 0},
    expiry: {mode: 'none', expiring_within_7_days: 0, expiring_units: 0, next_expiry_at: null},
    next_eligible_reward: {name: 'Free Kopi', cost_units: 6, remaining_units: remaining,
      available_now: availableNow, unit},
    visits_remaining: null, visit_progress: null,
    action: {reason: 'none', deadline_at: null, sort_band: 6, sort_units: 0},
  };
  if (ready !== undefined) value.ready_count = ready;
  if (chooseOne !== undefined) value.ready_choose_one = chooseOne;
  return value;
};

/* ------------------------------------------------------------------ R1: reading the payload --- */

test('R1: the count is read from the card, and a missing count is not zero', () => {
  assert.equal(H.customerCardReadyCountV465(card({ready: 2})), 2);
  assert.equal(H.customerCardReadyCountV465(card({ready: 0})), 0);
  assert.equal(H.customerCardReadyCountV465(card()), null, 'a pre-v465 payload yields null');
  assert.equal(H.customerCardReadyCountV465(card({ready: null})), null);
  assert.equal(H.customerCardReadyCountV465(card({ready: 'nonsense'})), null);
  assert.equal(H.customerCardReadyCountV465(card({ready: -3})), 0, 'never a negative promise');
  assert.equal(H.customerCardReadyCountV465(undefined), null);
});

test('R1: the server count outranks next_eligible_reward, in both directions', () => {
  /* next_eligible_reward is a progress candidate judged by older, narrower rules — no tier gate,
     no cycle-pinned stamp version, no restricted-reward filter. Where they disagree the count is
     the one that matches what the counter will honour. */
  assert.equal(H.customerCardRewardReadyV465(card({ready: 0, availableNow: true})), false,
    'the card claims a reward the server says is not claimable — the server wins');
  assert.equal(H.customerCardRewardReadyV465(card({ready: 2, availableNow: false})), true);
  assert.equal(H.customerCardRewardReadyV465(card({availableNow: true})), true,
    'with no count at all, the old flag still stands in');
  assert.equal(H.customerCardRewardReadyV465(card({availableNow: false})), false);
});

/* -------------------------------------------------------------- R1: the per-business card ---- */

test('R1: a business card prints the real number, singular and plural', () => {
  assert.equal(H.customerHomeBusinessStatusV345(card({ready: 1})), '1 reward ready');
  assert.equal(H.customerHomeBusinessStatusV345(card({ready: 2})), '2 rewards ready');
  assert.equal(H.customerHomeBusinessStatusV345(card({ready: 11})), '11 rewards ready');
});

test('R1: no count in the payload keeps v457 wording — the literal 1 does not come back', () => {
  const line = H.customerHomeBusinessStatusV345(card({availableNow: true}));
  assert.equal(line, 'Reward ready');
  assert.doesNotMatch(line, /\d/, 'a pre-apply server must not make Home state a quantity');
});

test('R1: a count of zero is not readiness — the card falls through to its progress line', () => {
  assert.equal(H.customerHomeBusinessStatusV345(
    card({ready: 0, availableNow: true, remaining: 3, unit: 'stamps'})),
    '3 stamps to go',
    'the old flag said ready, the server said none; the card must not claim readiness');
});

/* nestly_v571 (owner mark on My Rewards: "Choose 1 reward" struck out, "state how many rewards
   ready" written beside it). v428's phrasing hid the number on exactly the cards where several
   gifts share one stamp slot, so the same business read "5 rewards ready" in the greeting and
   "Choose 1 reward" on its own row. The count now wins on every surface, shared slot or not. */
test('R1: nestly_v571 the count is printed whether or not the gifts share one stamp slot', () => {
  assert.equal(H.customerHomeBusinessStatusV345(card({ready: 2, chooseOne: true})),
    '2 rewards ready');
  assert.equal(H.customerHomeBusinessStatusV345(card({ready: 2, chooseOne: false})),
    '2 rewards ready');
});

/* ------------------------------------------------------------------- R1: the greeting sums ---- */

const greetingLine = html => {
  const match = html.match(/<b>([^<]*)<\/b>/);
  assert.ok(match, `no headline in ${html}`);
  return match[1];
};

test('R1 INVARIANT: the greeting equals the sum of the numbers on the cards', () => {
  for (const counts of [[2, 3], [1, 0, 0], [4], [1, 1, 1, 1], [7, 2, 0, 5]]) {
    const cards = counts.map((ready, index) => card({name: `Shop ${index}`, ready}));
    const total = counts.reduce((sum, value) => sum + value, 0);
    const headline = greetingLine(H.customerHomeSummaryV343(cards));
    const printed = cards
      .map(value => H.customerHomeBusinessStatusV345(value))
      .filter(line => /reward/.test(line))
      .reduce((sum, line) => sum + Number(line.match(/^(\d+)/)?.[1] ?? 0), 0);
    assert.equal(headline, `${total} reward${total === 1 ? '' : 's'} ready`,
      `greeting for ${JSON.stringify(counts)}`);
    assert.equal(printed, total,
      'the greeting must equal what the cards below it actually print, not merely the same input');
  }
});

test('R1: every card at zero means the greeting claims nothing', () => {
  const html = H.customerHomeSummaryV343([card({ready: 0}), card({name: 'B', ready: 0})]);
  assert.doesNotMatch(html, /\d+ rewards? ready/, 'no quantity is claimed');
  assert.doesNotMatch(html, /is-ready-v2b/, 'and no ready styling either');
  assert.match(greetingLine(html), /No rewards ready yet|from a reward at/);
});

test('R1: one card without a count suppresses the total rather than printing a partial one', () => {
  const cards = [card({name: 'A', ready: 2}), card({name: 'B', availableNow: true})];
  assert.equal(greetingLine(H.customerHomeSummaryV343(cards)), 'Rewards ready',
    'a partial sum printed as a total is just a new way of being wrong');
  assert.equal(H.customerRewardReadyTotalV465(cards).known, false);
  assert.equal(H.customerRewardReadyTotalV465([card({ready: 2}), card({ready: 3})]).known, true);
  assert.equal(H.customerRewardReadyTotalV465([]).known, false, 'no cards is not a known zero');
});

test('R1: the greeting is derived from the same cards, so it cannot drift from the list', () => {
  const cards = [card({ready: 0, availableNow: true, remaining: 2})];
  const html = H.customerHomeSummaryV343(cards);
  assert.doesNotMatch(html, /is-ready-v2b/, 'no ready styling when the server says nothing is ready');
  assert.doesNotMatch(html, /reward ready/i);
});

test('R1: card mood, progress track and nearest-goal all read the one readiness answer', () => {
  const stale = card({ready: 0, availableNow: true, remaining: 4, balance: 2});
  assert.equal(H.customerCardMoodV2B(stale), '', 'no "ready" glow under a "4 stamps to go" line');
  assert.notEqual(H.customerCardProgressV2B(stale), '', 'the track is drawn, because there IS progress');
  assert.match(H.customerNearestGoalV2B([stale]), /4 stamps from a reward at/);

  const genuinely = card({ready: 2, availableNow: false, remaining: 4, balance: 2});
  assert.equal(H.customerCardMoodV2B(genuinely), ' is-reward-ready-v2b');
  assert.equal(H.customerCardProgressV2B(genuinely), '', 'nothing to progress toward once ready');
  assert.equal(H.customerNearestGoalV2B([genuinely]), '', 'a ready business is not "nearly" anything');
});

test('R1: how many BUSINESSES have something ready follows the same answer', () => {
  assert.equal(H.customerRewardReadyCountV343([
    card({ready: 3}), card({ready: 0, availableNow: true}), card({availableNow: true}),
  ]), 2, 'the middle card is stale-ready by the old flag and empty by the server');
});

/* ------------------------------------------------------------------------------ R6 -------- */

const summarySource = section('function customerBusinessRelationshipSummaryV346(',
  'function customerBusinessSecondaryMarkupV346');
/* The pill markup is executed by rendering the hero, which needs the whole customer-surface
   dependency tree; the attribute it writes is what R6 is about, so the fixture drives the two
   functions that produce and then consume it. */
const pillFallbackOf = html => html.match(/data-reward-ready-fallback-v397="([^"]*)"/)?.[1];
const pillTextOf = html => html.match(/data-reward-ready-fallback-v397="[^"]*">([^<]*)</)?.[1];

test('R6: the pill stores a fallback that makes no readiness claim', () => {
  /* Read off the source of the one attribute, because what the renderer STORES is the defect:
     the value must be the readiness-free sentence, never the painted `subline`. */
  assert.match(summarySource,
    /data-reward-ready-fallback-v397="\$\{esc\(progressSublineV465\)\}">\$\{esc\(subline\)\}/,
    'the fallback and the painted text are now two different strings');
  assert.match(summarySource, /const progressSublineV465=remaining>0/);
  assert.doesNotMatch(
    section('const progressSublineV465=remaining>0', 'const readySublineV465='),
    /customerRewardReadySignalV457|reward.{0,3}ready/i,
    'the fallback expression may not contain a readiness sentence at all');
});

test('R6 EXECUTING: catalogue resolves to 0 → the pill drops its readiness claim', () => {
  /* The exact shape the renderer emits: a node whose painted text says a reward is ready and whose
     stored fallback (post-v465) does not. */
  const node = () => ({
    textContent: 'Reward ready',
    dataset: {rewardReadyFallbackV397: '3 stamps to reward'},
  });
  const host = target => ({querySelectorAll: () => [target]});

  const toZero = node();
  H.customerRewardReadyCountApplyV397(0, host(toZero));
  assert.equal(toZero.textContent, '3 stamps to reward');
  assert.doesNotMatch(toZero.textContent, /ready/i,
    'B-REG-023: the pill must not re-assert readiness the catalogue has just disproved');

  const toTwo = node();
  H.customerRewardReadyCountApplyV397(2, host(toTwo));
  assert.equal(toTwo.textContent, '2 rewards ready');

  const toOne = node();
  H.customerRewardReadyCountApplyV397(1, host(toOne));
  assert.equal(toOne.textContent, '1 reward ready');
});

test('R6 NEGATIVE CONTROL: on the base commit the same fixture re-asserted readiness', () => {
  const before = execFileSync('git', ['show', 'b290151:app/app.js'],
    {cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024});
  const beforeSummary = sectionOf(before)('function customerBusinessRelationshipSummaryV346(',
    'function customerBusinessSecondaryMarkupV346');
  /* The defect, in one line: the stored fallback WAS the painted text, and the painted text on a
     ready card was customerRewardReadySignalV457(). */
  assert.match(beforeSummary,
    /data-reward-ready-fallback-v397="\$\{esc\(subline\)\}">\$\{esc\(subline\)\}/);
  assert.match(beforeSummary, /const subline=rewardReady\?customerRewardReadySignalV457\(\)/);

  const stale = {textContent: 'Reward ready', dataset: {rewardReadyFallbackV397: 'Reward ready'}};
  buildHarness(before).customerRewardReadyCountApplyV397(0, {querySelectorAll: () => [stale]});
  assert.equal(stale.textContent, 'Reward ready',
    'the pre-fix fallback restored the readiness claim at zero — this is B-REG-023 reproducing');
});

test('R1 NEGATIVE CONTROL: the base commit could not say a number at all', () => {
  const before = execFileSync('git', ['show', 'b290151:app/app.js'],
    {cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024});
  const beforeHarness = buildHarness(before);
  assert.equal(beforeHarness.customerHomeBusinessStatusV345(card({ready: 2, availableNow: true})),
    'Reward ready', 'v457 had no count to read, so a card with two ready said "Reward ready"');
  assert.equal(beforeHarness.customerHomeBusinessStatusV345(card({ready: 0, availableNow: true})),
    'Reward ready', 'and it said the same thing when nothing was ready at all');
  assert.equal(
    greetingLine(beforeHarness.customerHomeSummaryV343(
      [card({ready: 2, availableNow: true}), card({ready: 3, availableNow: true})])),
    'Rewards ready',
    'five rewards ready across two businesses, and the greeting could only say "Rewards ready" — '
    + 'ready_count was not a key the pre-v465 client had ever heard of');
  assert.equal(
    greetingLine(H.customerHomeSummaryV343(
      [card({ready: 2, availableNow: true}), card({ready: 3, availableNow: true})])),
    '5 rewards ready', 'and this is the same fixture through the fixed code');
  assert.equal(typeof beforeHarness.customerCardReadyCountV465, 'undefined');
});

/* -------------------------------------------------- the payload contract, both directions ---- */

test('the client reads exactly the two keys the migration adds, and invents no third', () => {
  const migration = readFileSync(
    path.join(root, 'db', 'migrations', '20260823_nestly_v465_home_ready_count.sql'), 'utf8');
  assert.match(migration, /'ready_count', \(ready\.payload->>'count'\)::integer/);
  assert.match(migration, /'ready_choose_one', \(ready\.payload->>'choose_one'\)::boolean/);
  /* The count is produced by the ONE availability core and by nothing else — the whole point of
     R1. If a future edit hand-rolls a balance comparison here, this fails. */
  assert.match(migration, /app\.reward_availability_v432\(p_business, p_client, p_as_of\) core/);
  assert.doesNotMatch(migration.slice(migration.indexOf('customer_ready_reward_count_v465'),
    migration.indexOf('§2')), /points_ledger|points_batches|stamp_progress_v323/);

  const readers = section('function customerCardReadyCountV465(', 'function customerRewardReadyTotalV465');
  assert.match(readers, /card\?\.ready_count/);
  assert.match(readers, /card\?\.ready_choose_one===true/);
  /* And the two sides use the same names, so a rename on either side breaks a test rather than a
     customer's Home screen. */
  for (const key of ['ready_count', 'ready_choose_one']) {
    assert.ok(migration.includes(`'${key}'`), `the migration must send ${key}`);
    assert.ok(readers.includes(key), `the client must read ${key}`);
  }
});

test('the rollback suite installs the migration\'s OWN bodies, byte for byte', () => {
  /* db/tests/v465_home_ready_count.sql installs the two functions inside its transaction so it can
     run against a database where v465 is not applied yet — which is the whole point of a pre-apply
     acceptance suite. That only proves anything while the installed bodies ARE the migration's. */
  const migration = readFileSync(
    path.join(root, 'db', 'migrations', '20260823_nestly_v465_home_ready_count.sql'), 'utf8');
  const suite = readFileSync(
    path.join(root, 'db', 'tests', 'v465_home_ready_count.sql'), 'utf8');
  const bodies = migration.slice(migration.indexOf('\nbegin;\n') + '\nbegin;\n'.length,
    migration.lastIndexOf('\ncommit;'));
  assert.ok(bodies.includes('create or replace function app.customer_ready_reward_count_v465'));
  assert.ok(bodies.includes('create or replace function app.c45_base_actionable_wallet_card')
    || bodies.includes('CREATE OR REPLACE FUNCTION app.c45_base_actionable_wallet_card'));
  assert.ok(suite.includes(bodies),
    'the suite has drifted from the migration it claims to prove — re-assemble it');

  /* And the deployed copy the migration is built on: every key the card sent before v465 must
     still be sent, because the ruling is additive. */
  for (const key of ['business', 'loyalty', 'credit', 'packages', 'expiry',
    'next_eligible_reward', 'visits_remaining', 'visit_progress', 'action']) {
    assert.ok(bodies.includes(`'${key}',`), `the card must still send ${key}`);
  }
});

test('both migration copies are byte-identical', () => {
  assert.equal(
    readFileSync(path.join(root, 'db', 'migrations',
      '20260823_nestly_v465_home_ready_count.sql'), 'utf8'),
    readFileSync(path.join(root, 'supabase', 'migrations',
      '20260823000002_nestly_v465_home_ready_count.sql'), 'utf8'));
});
