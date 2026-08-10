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
  /* V235: a Stamp card tile joins the two points tiles, so all THREE loyalty models are
     represented on the overview and exactly one of them can read Active. */
  assert.deepEqual(keys, ['points', 'tiers', 'stamps', 'lifestyle', 'promotions', 'referrals', 'recurring']);
  /* V244: the grid moved inside each of the two groups (Ongoing / Pending setup), so the
     render site emits the grouped markup rather than one bare grid. The tiles-mode gate — the
     thing this line actually protects — is unchanged. */
  assert.match(app, /\$\{growTilesModeV229\?growTilesHtmlV229:''\}/);
  assert.match(app, /growTileSectionV244\('Ongoing programmes'/);
  assert.match(shell, /\.grow-topic-tiles-v229\{display:grid/);
  // Tiles only exist on the default list view; Ongoing / To set up stay flat lists.
  assert.match(app, /const growTilesModeV229=programmeView==='list'&&!growActiveTopicV229;/);
  assert.match(app, /if\(programmeView!=='list'\)growTopicV229='';/);
  // Back out of a drill.
  assert.match(app, /id="growTopicBackV229"/);
});

test('V229 reward milestones live inside Point system, never on the tile overview', () => {
  /* V250 turned the milestone ROWS into the reward card grid the owner drew, so the mapping
     moved one step earlier into rewardCardsV250 and the points wrapper renders that grid. The
     containment this test protects — milestones belong to Point system and appear nowhere else
     — is unchanged, and is now checked at both ends. */
  const points = app.slice(app.indexOf("${topicOnV229('points')?`"), app.indexOf("${growActiveTopicV229?.key==='tiers'?"));
  assert.match(points, /rewardCardGridV250/);
  assert.equal((app.match(/rewardCardGridV250\b/g) || []).length, 2);
  assert.equal((app.match(/rewardJourney\.milestones\.map/g) || []).length, 1);
  const cards = app.slice(app.indexOf('const rewardCardsV250=['), app.indexOf('const rewardCardGridV250='));
  assert.match(cards, /rewardJourney\.milestones\.map/);
  // In tiles mode no topic is on, so no category rows exist at all.
  /* V235: Stamp card is a third VIEW of the point engine, so it drills into the points
     section rather than duplicating it — the mapping is what keeps the tile from dead-ending. */
  assert.match(app, /const growTopicSectionV235=growActiveTopicV229\?\.key==='stamps'\?'points':\(growActiveTopicV229\?\.key\|\|null\);/);
  /* V271 wrapped this with the Overview/History guard — those two views replace the category list
     rather than sitting above it. The drill-in vs tiles behaviour it protects is unchanged. */
  assert.match(app, /const topicOnV229=key=>!growCategoryViewV271\?false:\(growActiveTopicV229\?growTopicSectionV235===key:!growTilesModeV229\);/);
});

/* V240 (owner, Chagee): the exclusivity this test was written for is SUPERSEDED. Points and
   tiers may run together; what the server still holds the door on is points being spendable
   AND the tier's yardstick at once. The chooser therefore offers three ways, not two. */
test('V229/V240 a firm chooses how points are used, and the server holds the door', () => {
  // Unchosen: two cards. Chosen: the pill plus a switch to the OTHER mode only.
  assert.match(app, /Choose how customers use their points/);
  assert.match(app, /You can change this later\./);
  assert.match(app, /data-points-mode-v229="redeem"/);
  assert.match(app, /data-points-mode-v229="tiers"/);
  /* V235: the "Points are used for: X" chip plus a one-way "Switch to…" pill read as two half
     truths. All three models are now named with exactly one Live mark, and the change itself
     happens in one place — the editor's segmented toggle. */
  assert.match(app, /const liveLoyaltyModelV235=snapshot\.loyalty\?\.loyalty_model==='stamps'\?'stamps'/);
  assert.match(app, /live\?'<span aria-hidden="true">●<\/span> Live: ':''/);
  assert.match(app, /const loyaltyModelTileStatusV235=key=>/);
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

test('V229/V230 the loyalty editor shows ONE model, not both with banners', () => {
  /* V230 superseded the V229 banners: instead of showing both sections and flagging one as off,
     the editor renders only the chosen model's section, per the owner's "what is this Your
     rewards" and "tier should not be optional" reports. */
  assert.doesNotMatch(app, /Tier membership is off<\/b><p class="small"/);
  assert.match(app, /loyaltySelectionV230==='tiers'/);
  assert.match(app, /<b>Tiers — your loyalty model<\/b>/);
  assert.match(app, /Point rewards are off in this model\. Rewards you saved earlier are kept/);
  assert.match(app, /Tiers are off in this model — choose Tiered membership above/);
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
