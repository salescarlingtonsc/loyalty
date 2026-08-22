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

test('V358 the overview is eight peer topic tiles, and drilling in is the only way to the rows', () => {
  const defs = app.slice(app.indexOf('const growTopicDefsV229=['), app.indexOf('const growActiveTopicV229='));
  const keys = [...defs.matchAll(/\{key:'([a-z]+)'/g)].map((m) => m[1]);
  /* V235: a Stamp card tile joins the two points tiles, so all THREE loyalty models are
     represented on the overview and exactly one of them can read Active.
     V334 (owner markup, photo 3: "delete this tab"): the Promotions tile is struck out — Limited
     Offer already covers this surface from its own nav entry. */
  /* V358 (owner, photo 5: "remove this, take out everything outside" against the Lifestyle
     rewards card, with Welcome Gift / Birthday Benefit / Bring Back Rewards drawn as their own
     cards). The 'lifestyle' grouping tile is gone and its three programmes are peers here, so
     nothing sits one level deeper than the thing beside it. 'recurring' (Memberships) left the
     grid with the same pass. */
  assert.deepEqual(keys, ['points', 'tiers', 'stamps', 'welcome', 'birthday', 'bringback', 'referrals', 'recurring']);
  assert.ok(!keys.includes('lifestyle'), 'the grouping tile the owner struck out must not come back');
  /* V244: the grid moved inside each of the two groups (Ongoing / Pending setup), so the
     render site emits the grouped markup rather than one bare grid. The tiles-mode gate — the
     thing this line actually protects — is unchanged. */
  assert.match(app, /\$\{growTilesModeV229\?growTilesHtmlV229:''\}/);
  /* V343/V357 replaced the two fixed sections (Ongoing programmes / Pending setup) with one
     filter strip over the same tiles. Each count is rendered from the length of a real array, so
     the strip cannot advertise a number the grid does not contain. */
  assert.match(app, /data-grow-tile-filter-v357="all">All \(\$\{growDisplayTopicsV343\.length\}\)/);
  assert.match(app, /data-grow-tile-filter-v357="live">\$\{STATUS_WORDS\.on\} \(\$\{growDisplayLiveV343\.length\}\)/);
  assert.match(app, /data-grow-tile-filter-v357="pending">Not set up \(\$\{growDisplayPendingV343\.length\}\)/);
  /* nestly_v428 (item 3): History is the one count that could be UNKNOWN — it is read off the
     programme spine, and an unread spine must render no number rather than "(0)", which is what
     it printed for every firm forever. The count is still the length of the list it labels. */
  assert.match(app, /data-grow-tile-filter-v357="history">History\$\{growDisplayHistoryCountV343===null\?'':` \(\$\{growDisplayHistoryCountV343\}\)`\}/);
  /* V343 (owner markup: "photo 1 change to become photo 2"): the square-tile grid became a
     compact row list, one row per programme, inside its group's card border. */
  assert.match(shell, /\.grow-topic-tiles-v229\{display:flex;flex-direction:column/);
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
  /* V294 (owner: "expired don't show here, show in own history"): the one milestone mapping
     split into offer-grid and history halves — still the only two places milestones render. */
  assert.equal((app.match(/rewardJourney\.milestones\.filter\(milestone=>milestone\.availability!=='ended'\)\.map/g) || []).length, 1);
  assert.equal((app.match(/rewardJourney\.milestones\.filter\(milestone=>milestone\.availability==='ended'\)\.map/g) || []).length, 1);
  const cards = app.slice(app.indexOf('const rewardCardsV250=['), app.indexOf('const rewardCardGridV250='));
  assert.match(cards, /rewardJourney\.milestones\.filter\(milestone=>milestone\.availability!=='ended'\)\.map/);
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
  /* V314 (W6i1, 2026-08-14) — THE CHOOSER CARDS ARE DELETED, and this test is what would have
     kept them. They wrote businesses.points_mode directly, and after the switchboard inversion
     that column is frozen behind a tripwire that silently PINS the write: PostgREST answers 204,
     the toast fires, the page re-renders, the engine never hears. Worse, they rendered ONLY when
     points_mode was falsy — which every tenant created after v314 is, permanently — so the one
     surface that looked like the place to choose a model was the one that could not.
     The CAPABILITY is intact and is asserted here instead: the honest line that took the slot
     points at the setup wizard, and the wizard and the Grow editor's four-way toggle both write
     the choice through public.set_programmes_v314. The full pins live in
     tests/business-ui/v314-programme-switchboard.test.mjs. */
  assert.doesNotMatch(app, /Choose how customers use their points/);
  assert.doesNotMatch(app, /data-points-mode-v229=/);
  assert.match(app, /No points programme is set up yet/);
  assert.match(app, /The setup guide asks what points are for/);
  assert.match(app, /href="#\/grow\/setup"/);
  /* V235: the "Points are used for: X" chip plus a one-way "Switch to…" pill read as two half
     truths. All three models are now named with exactly one Live mark, and the change itself
     happens in one place — the editor's segmented toggle. */
  assert.match(app, /const liveLoyaltyModelV235=snapshot\.loyalty\?\.loyalty_model==='stamps'\?'stamps'/);
  assert.match(app, /live\?'<span aria-hidden="true">●<\/span> Live: ':''/);
  assert.match(app, /const loyaltyModelTileStatusV235=key=>/);
  // Switching states the concrete consequence and asks first — in the editor, the surviving door.
  assert.match(app, /Customers will not be able to claim point rewards until you switch back\./);
  assert.match(app, /writeProgrammeSwitchesV314\(S\.biz\.id,loyaltySelectionV230,/);
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
  /* V358 flattened the Lifestyle rewards grouping — Welcome gift, Birthday benefit and Bring-back
     are peers now, each with its own tile and its own door, so there is no grouping card left to
     carry that name. The categories that remain still carry the owner's words. */
  assert.doesNotMatch(app, /programme-category-title">Lifestyle rewards</,
    'the grouping the owner struck out must not come back');
  assert.match(app, /programme-category-title">Point system</);
  assert.match(app, /programme-category-title">Promotions</);
  assert.match(app, /programme-category-title">Referrals</);
  /* V294 (owner: "remove this programme"): the combined card went; Memberships stands alone
     and gift cards moved to the Serve & sell nav group. */
  assert.match(app, /programme-category-title">Memberships</);
  assert.doesNotMatch(app, /title:'Memberships & gift cards'/);
  assert.doesNotMatch(app, /programme-category-title">Memberships & gift cards</);
  assert.doesNotMatch(app, /programme-category-title">Promotions & growth</);
  assert.doesNotMatch(app, /programme-category-title">Other rewards</);
  assert.doesNotMatch(app, /programme-category-title">Recurring value</);
});
