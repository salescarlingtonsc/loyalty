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

test('the customer card locks the reward instead of hiding it, and names the tier', () => {
  /* v322: the same three facts, in the row the reward is now drawn as, and localized — every one
     of these strings was English on a Chinese, Malay and Tamil phone. */
  assert.ok(app.includes("tier_locked:ct('rewardLockedChip')"),
    'tier_locked missing from the customer availability map');
  assert.ok(app.includes("rewardLockedChip:'Locked'"), 'the locked chip needs its English entry');
  assert.ok(app.includes('const rewardLockLineV176='), 'no lock-line helper');
  assert.ok(app.includes("ct('rewardTierLock',{tier:label})"),
    'the locked line must name the tier — that is what makes climbing worth it');
  assert.ok(app.includes("rewardTierLock:'Reach {tier} to unlock this reward.'"));
  assert.ok(app.includes('customer-reward-row-chip-v322">${esc(chip)}'),
    'no state chip on the customer row');
  assert.ok(app.includes('${esc(rewardLockLineV176(r))}'),
    'the status line must prefer the tier-specific copy');
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
