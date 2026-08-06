import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V175: the publish diff listed redeem_points / reward_credit_cents for every model. Those
   columns drive redemption ONLY in the 'classic' model — app.redeem_points_v40_internal
   raises "this business redeems points through its reward catalog" otherwise — so under
   points_tiers a stale draft value rendered as "Points needed to redeem 1500 -> 150", which
   reads as a serious downgrade and blocks an owner from publishing a correct draft. Hit for
   real on 2026-08-06 while activating Cubbly's earning programme. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = (readFileSync(resolve(repoRoot, 'app/index.html'),'utf8')+'\n'+readFileSync(resolve(repoRoot, 'app/app.js'),'utf8'));

const start = app.indexOf('function growPublishFieldRowsV170');
assert.ok(start > 0);
const src = app.slice(start, app.indexOf('/* ============================ Program Studio page', start));
const rows = new Function(
  'GROW_PUBLISH_MODEL_LABEL_V170', 'GROW_PUBLISH_EXPIRY_LABEL_V170',
  'GROW_PUBLISH_TIER_BASIS_LABEL_V175', 'studioMoney',
  `${src}; return growPublishFieldRowsV170;`
)({classic:'Classic',points_tiers:'Points with milestones',stamps:'Stamp card'},
  {none:'Never expire',inactivity:'Expire after inactivity',fixed:'Fixed shelf life from earn'},
  {visits:'Number of visits',spend:'Lifetime spend',points_earned:'Lifetime points earned'},
  c => `SGD ${(Number(c||0)/100).toFixed(2)}`);

test('points_tiers hides inert classic redemption fields (the real 2026-08-06 case)', () => {
  const live  = {active:false, loyalty_model:'points_tiers', earn_points_per_dollar:10, redeem_points:1500, reward_credit_cents:1500, tier_basis:'visits'};
  const draft = {active:true,  loyalty_model:'points_tiers', earn_points_per_dollar:10, redeem_points:150,  reward_credit_cents:0,    tier_basis:'points_earned'};
  const labels = rows(live, draft).map(r => r.label);
  assert.ok(!labels.includes('Points needed to redeem'), 'inert under points_tiers');
  assert.ok(!labels.includes('Credit minted on redemption'), 'inert under points_tiers');
  assert.ok(labels.includes('Programme status'), 'the real change must still show');
  assert.ok(labels.includes('Tier level is earned by'), 'tier basis is a real customer-facing change');
});

test('classic still shows redemption fields — they are load-bearing there', () => {
  const live  = {active:true, loyalty_model:'classic', redeem_points:1500, reward_credit_cents:1500};
  const draft = {active:true, loyalty_model:'classic', redeem_points:800,  reward_credit_cents:2000};
  const labels = rows(live, draft).map(r => r.label);
  assert.ok(labels.includes('Points needed to redeem'));
  assert.ok(labels.includes('Credit minted on redemption'));
});

test('stamps shows stamp fields and hides points-per-dollar', () => {
  const live  = {active:true, loyalty_model:'stamps', stamp_target:8,  stamp_per_cents:500, earn_points_per_dollar:1};
  const draft = {active:true, loyalty_model:'stamps', stamp_target:10, stamp_per_cents:600, earn_points_per_dollar:5};
  const labels = rows(live, draft).map(r => r.label);
  assert.ok(labels.includes('Stamps needed for a reward'));
  assert.ok(labels.includes('Spend per stamp'));
  assert.ok(!labels.includes('Points earned per $1 spent'));
});

test('an unchanged draft still reports no rows', () => {
  const same = {active:true, loyalty_model:'points_tiers', earn_points_per_dollar:10, tier_basis:'points_earned'};
  assert.deepEqual(rows(same, {...same}), []);
  assert.deepEqual(rows(same, null), []);
});

test('V177: the confirm modal shows the diff, not just the safety check', () => {
  // The diff rendered on the page behind the modal, so at the moment of typing PUBLISH the
  // owner could not see what they were changing.
  const modal = app.indexOf("id=\"growPubModal\"");
  assert.ok(modal > 0);
  const src = app.slice(modal - 900, modal + 1400);
  assert.match(src, /publishDiffHtml/, 'modal must embed the rendered comparison');
  assert.match(src, /What changes for customers/, 'modal needs the diff heading');
  assert.match(app, /replace\(\/<button\[\\s\\S\]\*\?<\\\/button>\/gi,''\)/,
    'buttons must be stripped from the embedded copy to avoid duplicate ids');
  assert.match(app, /The programme numbers changing are listed above/,
    'confirm copy must point at the visible diff, not at editors elsewhere');
});
