import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V176 Stage B: tier-gated rewards, UI half.
   The gate is only real if all four of these hold, and each has a distinct way to rot:
     1. the editor OFFERS a tier, and only when the firm actually has tiers (otherwise the
        control is noise for a shop with no ladder);
     2. saveReward SENDS both min_tier_id and min_tier_threshold — sending only the id would
        leave the gate meaningless the moment the tier is deleted;
     3. the customer card renders LOCKED rather than hiding the reward, naming the tier —
        hiding it removes the reason to climb, which is the entire point of tiers;
     4. the locked card offers no redeem button.
   Assertions are placement-sensitive on purpose: an earlier increment in this session shipped
   a block that landed inside the wrong helper and silently never ran. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = (readFileSync(resolve(repoRoot, 'app/index.html'),'utf8')+'\n'+readFileSync(resolve(repoRoot, 'app/app.js'),'utf8'));

test('the tier picker lives in the reward editor, and only when tiers exist', () => {
  const editor = app.indexOf('function openRewardEditor(reward)');
  const editorEnd = app.indexOf('async function saveReward(archive)', editor);
  assert.ok(editor > 0 && editorEnd > editor, 'reward editor not found');
  const src = app.slice(editor, editorEnd);
  assert.ok(src.includes('id="rwMinTier"'), 'no tier picker in the reward editor');
  assert.ok(/\$\{tiers\.length\?`<div><label for="rwMinTier"/.test(src),
    'picker must be gated on tiers.length so tier-less firms never see it');
  assert.ok(src.includes('<option value="">Everyone</option>'),
    'ungated must be the default, spelled in plain words');
  assert.ok(/String\(r\.min_tier_id\|\|''\)===String\(t\.tier_id\|\|t\.id\)/.test(src),
    'an existing gate must re-select on reopen, or owners silently lose it');
});

test('saveReward sends BOTH the tier id and the threshold it stood at', () => {
  const start = app.indexOf('async function saveReward(archive)');
  const src = app.slice(start, start + 3000);
  assert.ok(src.includes('min_tier_id:minTierId'), 'tier id not sent');
  assert.ok(src.includes('min_tier_threshold:minTier?Number(minTier.threshold):null'),
    'threshold fallback not sent — a deleted tier would silently open the reward');
  assert.ok(src.indexOf('const minTierId=') < src.indexOf('min_tier_id:minTierId'),
    'minTierId must be resolved before the payload is built');
});

test('nestly_v422 REVERSES v176 on the customer list: a tier-gated reward is not shown there', () => {
  /* Owner ruling, 2026-08-22, on photo 6: "only show redeemable rewards after customer achieve the
     reward". v176's position was the opposite — a tier-gated reward stayed VISIBLE and locked,
     because naming the tier is what makes climbing worth it. The owner was shown that consequence
     in the question that produced this ruling ("Rewards not yet earned, tier-locked or ended
     disappear from this screen entirely") and chose it.
     WHAT SURVIVES OF V176, and is asserted below and in the tests after this one:
       · the SERVER-side gate is untouched — a tier-locked reward is still refused at the counter;
       · customerRewardCanRedeem still excludes it, so it can never gain a redeem button;
       · the OWNER's reward list still shows the gate at a glance;
       · the tier ladder on the customer's own page still names what each rung unlocks.
     Only the customer's Rewards LIST stopped rendering a card for it. */
  const rewards = app.slice(app.indexOf('const loadRewards=async()=>'),
    app.indexOf('const activityState={items:[],nextCursor:null}'));
  const rewardsCode = rewards.replace(/\/\*[\s\S]*?\*\//g, ' ');
  assert.ok(!rewardsCode.includes('customer-reward-locked-v339'),
    'no locked pill: the card is not rendered at all');
  assert.ok(!rewardsCode.includes('rewardLockLineV176'),
    'and no lock line, because there is nothing to label');
  assert.match(rewardsCode, /customerRewardCanRedeem\(item,redemptionEnabled\)/,
    'the list is the set the counter will honour, and nothing else');
  /* The shared availability copy still carries the tier_locked wording: the hero swipe pages
     (v399) read the same map and DO describe a reward the customer cannot take yet. */
  assert.ok(app.includes("tier_locked:'Unlocks at a higher tier'"),
    'tier_locked stays in the shared availability map the hero pages read');
});

test('a locked reward offers no redeem button', () => {
  const guard = app.indexOf('function customerRewardCanRedeem');
  assert.ok(guard > 0);
  const src = app.slice(guard, guard + 400);
  assert.ok(src.includes("reward?.availability!=='available_at_counter'"),
    'redeem eligibility must stay pinned to available_at_counter, which excludes tier_locked');
});

test('the owner reward list shows the gate at a glance, with a deleted-tier fallback', () => {
  assert.ok(app.includes('const rewardTierGateLabelV176='), 'no owner-side gate label helper');
  assert.ok(app.includes('🔒 ${esc(rewardTierGateLabelV176(r))} and above'),
    'the owner list must show which tier a reward is behind');
  const start = app.indexOf('const rewardTierGateLabelV176=');
  const src = app.slice(start, start + 500);
  assert.ok(src.includes('r.min_tier_threshold==null?\'\':'),
    'a gate whose tier was deleted must still render as gated, not as ungated');
});
