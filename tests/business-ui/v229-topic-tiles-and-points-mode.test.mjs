/* V229 — the owner's Programmes restructure, and the one-choice points rule.
   (1) "i need a clean overview before zooming in ... square boxes for each topics then press in"
   (2) "example owner created 10 points to redeem free spa 30mins - it should be under point
       system (not flooded in the overview page)"
   (3) "firms can only choose 1 ... earn points to redeem ... or earn points to be tiered member"
   Server behaviour is proved by the rolled-back production chain (7/7); these pin the client. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const shell = readFileSync(join(root, 'app', 'index.html'), 'utf8');
const migration = readFileSync(join(root, 'db', 'migrations', '20260808_nestly_v229_points_mode_choice.sql'), 'utf8');

test('V229 the overview is six topic tiles, and drilling in is the only way to the rows', () => {
  const defs = app.slice(app.indexOf('const growTopicDefsV229=['), app.indexOf('const growActiveTopicV229='));
  const keys = [...defs.matchAll(/\{key:'([a-z]+)'/g)].map((m) => m[1]);
  assert.deepEqual(keys, ['points', 'tiers', 'lifestyle', 'promotions', 'referrals', 'recurring']);
  assert.match(app, /growTilesModeV229\?`<div class="grow-topic-tiles-v229">/);
  assert.match(shell, /\.grow-topic-tiles-v229\{display:grid/);
  // Tiles only exist on the default list view; Ongoing / To set up stay flat lists.
  assert.match(app, /const growTilesModeV229=programmeView==='list'&&!growActiveTopicV229;/);
  assert.match(app, /if\(programmeView!=='list'\)growTopicV229='';/);
  // Back out of a drill.
  assert.match(app, /id="growTopicBackV229"/);
});

test('V229 reward milestones live inside Point system, never on the tile overview', () => {
  // The milestone rows render only inside the points wrapper...
  const points = app.slice(app.indexOf("${topicOnV229('points')?`"), app.indexOf("${growActiveTopicV229?.key==='tiers'?"));
  assert.match(points, /rewardJourney\.milestones\.map/);
  // ...and nowhere else in the file's render paths.
  assert.equal((app.match(/rewardJourney\.milestones\.map/g) || []).length, 1);
  // In tiles mode no topic is on, so no category rows exist at all.
  assert.match(app, /const topicOnV229=key=>growActiveTopicV229\?growActiveTopicV229\.key===key:!growTilesModeV229;/);
});

test('V229 a firm chooses ONE use for points, and the server holds the door', () => {
  // Unchosen: two cards. Chosen: the pill plus a switch to the OTHER mode only.
  assert.match(app, /Choose how customers use their points/);
  assert.match(app, /One model at a time keeps the customer story clear/);
  assert.match(app, /data-points-mode-v229="redeem"/);
  assert.match(app, /data-points-mode-v229="tiers"/);
  assert.match(app, /Points are used for: \$\{currentLabel\}/);
  // Switching states the concrete consequence and asks first.
  assert.match(app, /Customers will not be able to claim point rewards until you switch back\./);
  assert.match(app, /sb\.from\('businesses'\)\.update\(\{points_mode:next\}\)/);
  // In tiers mode the redeemable rows are swapped for a truthful note.
  assert.match(app, /\$\{pointsModeV229==='tiers'\?growTiersModeNoteV229:`/);
  assert.match(app, /Rewards created earlier are kept, and customers cannot claim them while tiers run\./);
  // The server refuses redemption intents in tiers mode, before identity resolution.
  assert.match(migration, /points here count toward membership tiers and cannot be redeemed/);
  assert.match(migration, /points_mode in \('redeem','tiers'\)/);
  assert.match(migration, /set points_mode='redeem'\nwhere points_mode is null\n  and exists\(select 1 from public\.loyalty_programs/);
});

test('V229 the loyalty editor states the mode instead of silently offering both', () => {
  assert.match(app, /Tier membership is off<\/b><p class="small"[^<]*>This business redeems points for rewards\./);
  assert.match(app, /Redemption is off<\/b><p class="small"[^<]*>Points count toward tier membership, so customers cannot claim these rewards\./);
});

test('V229 categories carry the owner\'s names', () => {
  assert.match(app, /programme-category-title">Lifestyle rewards</);
  assert.match(app, /programme-category-title">Promotions</);
  assert.match(app, /programme-category-title">Referrals</);
  assert.match(app, /programme-category-title">Memberships & gift cards</);
  assert.doesNotMatch(app, /programme-category-title">Promotions & growth</);
  assert.doesNotMatch(app, /programme-category-title">Other rewards</);
  assert.doesNotMatch(app, /programme-category-title">Recurring value</);
});
