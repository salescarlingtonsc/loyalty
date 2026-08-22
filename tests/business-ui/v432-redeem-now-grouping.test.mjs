/* nestly_v432 — the staff redeem-now list groups server-approved rewards by their source.
 *
 * Owner ruling 2026-08-22: no hidden counter-only gifts. Eligibility is the SERVER's
 * (app.reward_availability_v432 — proven end to end in
 * db/tests/executed/v432_staff_redeem_list_matches_customer.sql, which pins that a customer
 * with 2 claimable stamp gifts sees exactly those 2 in Customer View AND staff redeem-now).
 * This file covers the browser half: the grouping function is EXECUTED, not grepped —
 * it must bucket by the server's `source` tag, label the buckets, keep a stable order,
 * and never drop a server-approved reward it does not recognise (dropping one would be a
 * second, client-side eligibility rule — the thing v145 forbids).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');
const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start} … ${end}`);
  return app.slice(from, to);
};

/* The grouping function, evaluated exactly as it ships. */
const groupSource = section('function groupRedeemableRewardsV432(', 'async function tillPage(');
const groupRedeemableRewardsV432 = new Function(`${groupSource}; return groupRedeemableRewardsV432;`)();

test('v432: rewards bucket by the server source, stamp card first, labels human', () => {
  const groups = groupRedeemableRewardsV432([
    { reward_id: 'p1', name: 'Free Lotion', source: 'points' },
    { reward_id: 's1', name: 'Card Gift A', source: 'stamp_card' },
    { reward_id: 's2', name: 'Card Gift B', source: 'stamp_card' },
  ]);
  assert.equal(groups.length, 2);
  assert.equal(groups[0].source, 'stamp_card');
  assert.equal(groups[0].label, 'Stamp card');
  assert.deepEqual(groups[0].rewards.map(reward => reward.reward_id), ['s1', 's2']);
  assert.equal(groups[1].source, 'points');
  assert.equal(groups[1].label, 'Points');
  assert.deepEqual(groups[1].rewards.map(reward => reward.reward_id), ['p1']);
});

test('v432: a source this build does not know is still rendered, never dropped', () => {
  const groups = groupRedeemableRewardsV432([
    { reward_id: 'x1', name: 'Mystery', source: 'welcome_gift' },
    { reward_id: 's1', name: 'Card Gift A', source: 'stamp_card' },
    { reward_id: 'x2', name: 'No tag at all' },
  ]);
  const rendered = groups.flatMap(group => group.rewards.map(reward => reward.reward_id));
  assert.deepEqual(rendered.sort(), ['s1', 'x1', 'x2']);
  const fallback = groups.find(group => group.source === 'other');
  assert.ok(fallback, 'unrecognised sources fall into a fallback group');
  assert.equal(fallback.label, 'Rewards');
  assert.equal(groups[0].source, 'stamp_card', 'known sources still lead');
});

test('v432: empty and malformed input renders nothing, and throws nothing', () => {
  assert.deepEqual(groupRedeemableRewardsV432([]), []);
  assert.deepEqual(groupRedeemableRewardsV432(null), []);
  assert.deepEqual(groupRedeemableRewardsV432([null, undefined]), []);
});

/* The banner consumes the grouping and the per-reward unit — structural pins on the exact
 * consumption sites, so a refactor that stops calling the executed function above goes red. */
test('v432: the till banner renders groups from the server list and prices each row in its own unit', () => {
  const banner = section('const affordableV392=', 'id="tGiftScanV392"');
  assert.match(banner, /affordableV392=giftsV392\.filter\(gift=>gift\.available_now===true\)/,
    'the list is available_now===true — the SERVER answer, nothing recomputed');
  assert.match(banner, /groupRedeemableRewardsV432\(affordableV392\)/,
    'the groups are built from that same server-approved list');
  assert.match(banner, /till-reward-group-v432[\s\S]*?esc\(group\.label\)/, 'each group is labelled');
  assert.match(banner, /gift\.unit==='stamps'\?'stamps':gift\.unit==='points'\?'points':giftUnitV392/,
    'the row price uses the reward’s own unit, programme unit only as fallback');
  assert.match(banner, /data-unit-v432/, 'the redeem button carries the unit into the v404 dialog');
  assert.match(banner, /availability==='insufficient_balance'/,
    'the "Not yet" teaser is only a genuine-progress reward, never a not_on_card or claimed row');
});

test('v432: the v404 dialog takes the clicked reward’s unit', () => {
  const dialog = section('function openManualRedeemConfirmV404(', 'function tillItemsStageHtmlV373(');
  assert.match(dialog, /rewardUnit==='stamps'\|\|rewardUnit==='points'/,
    'the dialog prefers the per-reward unit and falls back to the programme unit');
  const handler = section('openManualRedeemConfirmV404({', 'quantity:tillManualQtyV404');
  assert.match(handler, /rewardUnit:button\.dataset\.unitV432/,
    'the click handler forwards data-unit-v432');
});
