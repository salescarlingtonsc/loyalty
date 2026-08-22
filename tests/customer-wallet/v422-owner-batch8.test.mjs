/* nestly_v422 — the owner's eight annotated screens, 2026-08-21.
 *
 * This file covers the CUSTOMER half. The business half (the typed card length, the deleted
 * preview, the Add-a-gift dialog) is in tests/business-ui/v416-stamp-card-editor.test.mjs, beside
 * the editor it changes.
 *
 * The renderers are EXECUTED, not matched in the source, wherever they can be: a grep stays green
 * while the behaviour behind it is dead.
 *
 * Photos and rulings covered here:
 *   photo 4  "for stamps dont need show this"  — the 13 / 13 stamps figure on the My Rewards tile
 *   photo 5  "don't write this"                — the same figure on the home "Your Peekaa" card
 *   photo 6  "remove this wording"             — the retired stamp-card sentence, and its box
 *   photo 6  "Available" / "History" tabs, "only show redeemable rewards after customer achieve
 *            the reward", "once redeemed, rewards go history"
 *   photo 8  "remove this wording"             — the Locations chip's label
 *   photo 8  the hero redrawn as the whole stamp card, stars on collected slots, a gift on the
 *            slots that pay out, "Next available Reward: xxxx", Claim Reward + Book now
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');
const indexHtml = await readFile(new URL('../../app/index.html', import.meta.url), 'utf8');
const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start} … ${end}`);
  return app.slice(from, to);
};
/* Comments are stripped wherever a test asserts that copy or an identifier is GONE: several of the
   removed strings survive inside the comments recording why they were removed. */
const code = source => source.replace(/\/\*[\s\S]*?\*\//g, ' ');

const esc = v => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const CUI = { icon: name => `<svg data-icon="${name}"></svg>` };

/* The stamp-card hero and the two wallet-figure helpers, evaluated exactly as they ship. */
const harness = new Function('esc', 'CUI', `
  ${section('const CUSTOMER_COPY=Object.freeze({', 'const normalizeCustomerLocale=')}
  let customerLocale='en';
  ${section('function ct(key,vars={}){', 'function customerMediaUrlV95')}
  ${section('function customerPointTotalV103(', 'const CUSTOMER_SEEN_OFFERS_KEY_V167')}
  ${section('function stampQuestNormaliseV323(', 'function customerStampQuestRingsV323')}
  ${section('const HERO_STAMP_COMPACT_FROM_V422=', 'function customerBusinessRelationshipSummaryV346(')}
  ${section('const PROGRAMME_STACK_MIN_CONTRACT_V395=', '/* Fixed, regardless of which are on.')}
  ${section('const PROGRAMME_STACK_ORDER_V310=', 'function programmeStackCardVisibleV310')}
  ${section('function programmeStackCardVisibleV310(', '/* One paused block, used by whichever card is paused.')}
  ${section('function customerProgrammeCardProgrammesV360(', 'function customerProgrammeTileMarkupV96')}
  ${section('function customerHomeBusinessBalanceV345(', 'function customerHomeBusinessCardV345')}
  ${/* nestly_v428: the three helpers the go-live review changed, executed here rather than
        grepped — two of them decide what a customer is TOLD they can claim. */''}
  ${section('function customerRewardProgressMarkupV310(', '/* How many rings the card draws.')}
  ${section('const customerRewardReadyLineV397=', '/* nestly_v399. The final swipe page')}
  ${section('function customerRewardReadyCountApplyV397(', '/* nestly_v399. The customer-facing words')}
  return {stampQuestNormaliseV323, customerHeroStampCardV422,
    customerProgrammeDirectoryMetricV346, customerProgrammeDirectoryStatusV346,
    customerHomeBusinessBalanceV345, HERO_STAMP_COMPACT_FROM_V422,
    customerRewardProgressMarkupV310, customerStampChooseOneSlotV428,
    customerRewardReadyCountApplyV397};`)(esc, CUI);

const quest = (slots, filled, milestones = []) => harness.stampQuestNormaliseV323({
  enabled: true, contract: 'v323', running: true, ready: true,
  slots, filled, cycle_index: 1, milestones
});
const stampsCard = (balance, remaining = 0, ready = false) => ({
  loyalty: { balance, unit: 'stamps', model: 'stamps' },
  next_eligible_reward: { cost_units: 5, remaining_units: remaining, available_now: ready }
});

/* ------------------------------------------------------ photos 4 + 5: the struck-out figures --- */

test('photo 4: a stamps firm contributes no balance figure to the My Rewards tile', () => {
  const { customerProgrammeDirectoryMetricV346: metric } = harness;
  assert.equal(metric(stampsCard(13, 0, true)), '',
    '"13 / 13 stamps" is the figure the owner ringed with "for stamps dont need show this"');
  assert.equal(metric(stampsCard(2, 3)), '', 'and a part-filled card prints nothing either');
  /* Points are untouched: a points balance is a number the customer spends and has to know. */
  assert.equal(metric({ loyalty: { balance: 240, unit: 'points' } }), '240 pts');
  /* Membership and packages keep their own figures, and still outrank the points balance. */
  assert.equal(metric({ loyalty: { balance: 240, unit: 'points' }, membership: { active: true } }), 'Member');
  assert.equal(metric({ loyalty: { balance: 240, unit: 'points' }, packages: { sessions_remaining: 3 } }), '3 sessions');
});

test('photo 4: the status line the tile still shows is the one that tells the customer to walk in', () => {
  const { customerProgrammeDirectoryStatusV346: status } = harness;
  assert.equal(status(stampsCard(13, 0, true)), '1 reward ready');
  assert.equal(status(stampsCard(2, 3)), '3 stamps to reward');
});

test('photo 5: the home "Your Peekaa" card prints no stamps line', () => {
  const { customerHomeBusinessBalanceV345: balance } = harness;
  assert.equal(balance(stampsCard(13, 0, true)), '');
  assert.equal(balance(stampsCard(2, 3)), '');
  assert.equal(balance({ loyalty: { balance: 240, unit: 'points' } }), '240 pts');
});

test('photos 4 + 5: an empty figure leaves no empty box behind it', () => {
  /* Returning '' from the two helpers above is only half the fix — a `<b></b>` or a `<strong></strong>`
     with nothing in it still occupies its grid column and still draws its own type styling. */
  assert.match(app, /\$\{metric\?`<div class="customer-programme-card-balance"><b>\$\{esc\(metric\)\}<\/b>/,
    'the tile drops the whole balance box when there is no metric');
  assert.match(app, /\$\{customerHomeBusinessBalanceV345\(card\)\?`<strong>/,
    'and the home card drops its balance line');
});

/* ------------------------------------------------ photo 8: the hero IS the stamp card ---------- */

test('photo 8: the hero draws every slot on the card, with a star on each one collected', () => {
  const html = harness.customerHeroStampCardV422(quest(15, 8, [
    { slot: 5, name: 'Free Drink', stamps_to_go: 0, claimed_this_cycle: true },
    { slot: 10, name: 'Free Facial', stamps_to_go: 2, claimed_this_cycle: false },
    { slot: 15, name: 'Free Massage', stamps_to_go: 7, claimed_this_cycle: false }
  ]));
  const slots = [...html.matchAll(/data-hero-stamp-slot-v422="(\d+)"/g)].map(m => Number(m[1]));
  assert.deepEqual(slots, [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],
    'every stamp on the card, in order — the owner drew the whole card, not a window on it');
  assert.equal((html.match(/is-filled/g) || []).length, 8, 'one star per collected stamp');
  assert.equal((html.match(/customer-hero-stamp-gift-v422/g) || []).length, 3,
    'a gift on each slot that pays out');
  assert.match(html, /data-hero-stampcard-v422="8\/15"/);
  /* "if got stamp put star" — a collected slot shows a star, not its number. */
  assert.doesNotMatch(html, /is-filled[^>]*>\s*<span class="customer-hero-stamp-num-v422">/);
});

test('photo 8: the hero names the next reward instead of counting anonymous ones', () => {
  const html = harness.customerHeroStampCardV422(quest(10, 6, [
    { slot: 5, name: 'Free Drink', stamps_to_go: 0, claimed_this_cycle: true },
    { slot: 10, name: 'Free Facial', stamps_to_go: 4, claimed_this_cycle: false }
  ]));
  assert.match(html, /Next available Reward: Free Facial/,
    'the first UNCLAIMED milestone — the server\'s own quest.next, never a guess');
  /* With every milestone on the card claimed there is nothing to promise, and it says so rather
     than naming a reward the counter would refuse. */
  const done = harness.customerHeroStampCardV422(quest(5, 5, [
    { slot: 5, name: 'Free Drink', stamps_to_go: 0, claimed_this_cycle: true }
  ]));
  assert.match(done, /Next available Reward: all claimed on this card/);
});

test('photo 8: two gifts on one stamp draw one marker, and the line names the claimable one', () => {
  /* This is Cubbly's real shape: "Free Lotion" and "Free Massage Oil" both sit on stamp 5. */
  const html = harness.customerHeroStampCardV422(quest(5, 5, [
    { slot: 5, name: 'Free Lotion', stamps_to_go: 0, claimed_this_cycle: false },
    { slot: 5, name: 'Free Massage Oil', stamps_to_go: 0, claimed_this_cycle: false }
  ]));
  assert.equal((html.match(/customer-hero-stamp-gift-v422/g) || []).length, 1,
    'one slot, one gift mark — two glyphs on one circle is not a picture of anything');
  assert.match(html, /Next available Reward: Free Lotion/);
});

test('photo 8: a claimed milestone never becomes the "next" one', () => {
  const html = harness.customerHeroStampCardV422(quest(5, 5, [
    { slot: 5, name: 'Already taken', stamps_to_go: 0, claimed_this_cycle: true },
    { slot: 5, name: 'Still available', stamps_to_go: 0, claimed_this_cycle: false }
  ]));
  assert.match(html, /Next available Reward: Still available/);
});

test('photo 8: a long card gets smaller circles, never a truncated card', () => {
  /* Owner ruling 2026-08-22: "draw all of them, wrapping into rows". */
  const long = harness.customerHeroStampCardV422(quest(40, 17,
    [{ slot: 40, name: 'Free session', stamps_to_go: 23, claimed_this_cycle: false }]));
  assert.equal([...long.matchAll(/data-hero-stamp-slot-v422="\d+"/g)].length, 40);
  assert.match(long, /is-compact-v422/, `past ${harness.HERO_STAMP_COMPACT_FROM_V422} the cells step down a size`);
  assert.doesNotMatch(long, /Showing the first/, 'nothing is hidden, so nothing has to be excused');
  const short = harness.customerHeroStampCardV422(quest(10, 3, []));
  assert.doesNotMatch(short, /is-compact-v422/);
  assert.match(indexHtml, /\.customer-hero-stamp-grid-v422\{display:grid;grid-template-columns:repeat\(auto-fit,28px\)/,
    'the grid auto-fits rather than pinning a fixed count per row');
});

test('photo 8: a card with no slots draws nothing rather than an empty frame', () => {
  assert.equal(harness.customerHeroStampCardV422(quest(0, 0, [])), '');
  assert.equal(harness.customerHeroStampCardV422(null), '');
});

test('photo 8: carried stamps are said out loud, never absorbed', () => {
  /* Cubbly's real state: 753 stamps against a 5-slot card. The card shows 5 of 5; the rest is a
     fact the customer owns and must not vanish into an invisible completed card. */
  const html = harness.customerHeroStampCardV422(quest(5, 753,
    [{ slot: 5, name: 'Free Lotion', stamps_to_go: 0, claimed_this_cycle: false }]));
  assert.match(html, /data-hero-stampcard-v422="5\/5"/);
  assert.match(html, /748 already counted toward your next card/);
});

test('photo 8: the hero paints from the wallet first and is replaced by the real card', () => {
  const hero = section('function customerBusinessRelationshipSummaryV346(',
    'function customerBusinessSecondaryMarkupV346');
  assert.match(hero, /data-hero-stamp-slot-host-v422/,
    'the stamps figure is a slot, so an unanswered v323 read leaves today\'s rings standing');
  const loader = section('const loadStampCardV323=async()=>', 'const loadGrowthOffers=async()=>');
  assert.match(loader, /heroSlotV422\.innerHTML=heroCardV422/);
  assert.match(loader, /if\(!card&&!heroSlotV422\)return;/,
    'the read fires for EITHER surface — the stamps card lives in a sub-page the hero does not');
  /* The card is authoritative about readiness, so a hero painted before it arrived can gain the
     Claim button — through the SAME contract and the same wiring, never a second claim path. */
  assert.match(loader, /data-claim-reward-scroll-v337/);
  assert.match(loader, /wireCustomerClaimRewardV395\(actionsV422\)/);
  assert.match(loader, /quest\.ready&&actionsV422&&!actionsV422\.querySelector\('\[data-claim-reward-scroll-v337\]'\)/,
    'and only when it is not already there');
});

test('photo 8: stamps mode drops the ready-count pill; points and tiers keep it', () => {
  const hero = section('function customerBusinessRelationshipSummaryV346(',
    'function customerBusinessSecondaryMarkupV346');
  assert.match(hero, /\$\{modeV386==='stamps'\?''\s*\n?\s*:`<span class="customer-business-ready-v347">/,
    'the owner\'s redraw carries no count chip; "Next available Reward: X" replaces it');
  assert.match(hero, /data-reward-ready-count-v397/,
    'the v397/v399 hook survives for the two modes that still show it');
});

/* ---------------------------------------- photo 8: the Locations chip loses its word ----------- */

test('photo 8: the compact header chip is a pin, and the wide header still prints the address', () => {
  const contact = section('const contactHostV326=', 'const loadStampCardV323=async()=>');
  assert.match(contact, /const rawAddressLabelV366=compactHeaderContactV366\?''/);
  assert.match(contact, /:\(branch\.address\?String\(branch\.address\):'Locations'\)/,
    'the wide header has the room and there the address is the useful label');
  assert.match(contact, /\$\{rawAddressLabelV366\?`<span>\$\{esc\(rawAddressLabelV366\)\}<\/span>`:''\}/,
    'no empty span when there is no label');
  assert.match(contact, /customer-business-address-icon-v422/);
  /* The address is not lost — it is the chip's title and part of its accessible name, and v386
     prints it in full on its own line directly below. */
  assert.match(contact, /title="\$\{esc\(addressTitleV366\)\}"/);
  assert.match(contact, /`Locations — \$\{addressTitleV366\}`/);
  assert.match(contact, /data-company-address-line-v386/);
});

test('photo 8: the freed width is what gives the name and the bio their own line', () => {
  /* MEASURED in Chrome at 390px on the build in the owner's photos: header track
     28px | 1fr | minmax(166px,184px) gave the actions 184px and left the identity button 130px,
     of which 89px was text column — so "Cubbly SPA" wrapped to two line boxes and ellipsised, and
     the bio needed 120px in that 89px box and broke mid-phrase, which is the owner's second mark
     on the same photo. Re-measured after, at 375/390/412: actions 101-106px, text column
     114-122px, name ONE un-truncated line, bio ONE line box. */
  assert.match(indexHtml, /\.customer-business-header-v346\{grid-template-columns:28px minmax\(0,1fr\) auto!important/);
  assert.match(indexHtml, /\.customer-business-actions-v346\{grid-column:3!important;grid-row:1!important;display:grid!important;grid-template-columns:auto 34px!important/);
  assert.match(indexHtml, /@media\(max-width:380px\)\{\.customer-business-header-v346\{grid-template-columns:24px minmax\(0,1fr\) auto!important/,
    'and at the narrow breakpoint too');
  assert.match(indexHtml, /\.customer-business-identity-v346 small\{display:block/,
    'the sector and the bio are each their own line, which is what the freed width makes readable');
});

/* ------------------------------------------------- photo 6: Available / History ---------------- */

test('photo 6: the rewards list shows only what the counter will honour', () => {
  const rewards = section('const loadRewards=async()=>', 'const activityState={items:[],nextCursor:null}');
  const rewardsCode = code(rewards);
  assert.match(rewardsCode,
    /const claimableRewardsV422=rewards\.filter\(item=>item\.action_key&&customerRewardCanRedeem\(item,redemptionEnabled\)\)/,
    'the same predicate the hero ready-count uses, so the pill and the list cannot disagree');
  /* Everything the owner struck through on that photo belonged to a card that could not be
     claimed. None of those states can occur on this list any more, so they are gone rather than
     left as branches that can never be true. */
  for (const gone of ['inProgressV340', 'rewardLockLineV176', 'customer-reward-locked-v339',
    'customer-reward-progress-read-v340', 'more to go', 'wallet-reward-progress',
    'availability[r.availability]']) {
    assert.ok(!rewardsCode.includes(gone), `${gone} must not survive on this list`);
  }
  /* And the one card shape that remains carries the action. */
  assert.match(rewardsCode, /<span class="pill ok">Ready to claim<\/span>/);
  assert.match(rewardsCode, /data-customer-redeem="\$\{esc\(r\.action_key\)\}"/);
});

test('photo 6: the claim button sits under the reward it claims, not above it', () => {
  /* Not an owner mark — a consequence of one. The narrow card template named TWO rows,
     'photo copy' and 'action action', so the button took row 2 while the name, the cost and the
     description auto-placed into implicit rows 3 and below: MEASURED on origin/main at 390px, the
     action's top was 130 and the name's was 180. It went unseen because a card only carries that
     button when the reward is claimable, and this list was mostly cards that were not. Every card
     on the Available tab has one now, so it had to be right. */
  assert.match(indexHtml,
    /\.wallet-rewards\.customer-rewards-carousel-v337 \.wallet-reward\{max-width:none;\s*\n\s*display:grid;grid-template-columns:64px minmax\(0,1fr\);grid-template-areas:'photo copy';/,
    'the action row is gone from the narrow template, so the button auto-places after the copy');
  assert.match(indexHtml, /\.customer-rewards-carousel-v337 \.wallet-reward-actions\{grid-column:1\/-1;margin-top:8px\}/);
  /* The wide layout still puts the action on the row's own line, so it must keep the named area. */
  assert.match(indexHtml, /@media\(min-width:641px\)\{[\s\S]*?grid-template-areas:'photo copy action'[\s\S]*?\.customer-rewards-carousel-v337 \.wallet-reward-actions\{grid-area:action;margin-top:0\}/,
    'the wide row is unchanged and still names the area it places into');
});

test('photo 6: Available and History are tabs, and History is not fetched until it is opened', () => {
  const rewards = section('const loadRewards=async()=>', 'const activityState={items:[],nextCursor:null}');
  assert.match(rewards, /data-rewards-tab-v422="available"/);
  assert.match(rewards, /data-rewards-tab-v422="history"/);
  assert.match(rewards, /data-rewards-panel-v422="history" role="tabpanel" hidden/,
    'History starts hidden');
  assert.match(rewards, /if\(wanted==='history'\)loadRewardHistoryV422\(\)/);
  assert.match(rewards, /if\(rewardHistoryLoadedV422\)return;\s*\n?\s*rewardHistoryLoadedV422=true;/,
    'fetched once, on first open — most customers open this screen to claim, not to reminisce');
  /* A tab cannot carry a count for something not yet read; guessing one would be a fabrication. */
  assert.doesNotMatch(rewards, /History\$\{[a-zA-Z]*[Hh]istory[a-zA-Z]*\.length/);
  /* nestly_v429 (C): the count is what the panel PAINTS — the claimable catalogue rewards plus the
     v427 entitlements the counter already owes this customer, both of which have been read by the
     time it is printed. A voucher sitting in the panel uncounted would make the number an
     undercount of what the customer can walk in and use. */
  assert.match(rewards, /Available\$\{claimableRewardsV422\.length\+entitlementsV429\.length\?` \(\$\{claimableRewardsV422\.length\+entitlementsV429\.length\}\)`:''\}/,
    'Available does carry a count, because it has been read');
  assert.match(rewards, /const entitlementsV429=!entitlementsResultV427\?\.error&&Array\.isArray\(entitlementsResultV427\?\.data\?\.active\)/,
    'and it is the server\'s own active list, empty on any refusal');
});

test('photo 6: an unread History failure is distinguishable from an empty one', () => {
  const rewards = section('const loadRewards=async()=>', 'const activityState={items:[],nextCursor:null}');
  assert.match(rewards, /Nothing claimed yet\. Rewards you redeem show up here\./);
  assert.match(rewards, /We could not load your claimed rewards\./);
  assert.match(rewards, /data-rewards-history-retry-v422/, 'and a real failure offers a retry');
  assert.match(rewards, /rewardHistoryLoadedV422=false;\s*\n?\s*const missing=\['42883','PGRST202'\]\.includes/,
    'a failed read is not marked loaded, so the retry genuinely re-requests');
  assert.match(rewards, /renderRewardHistoryV422\(missing\?'unavailable':'error'\)/,
    'an old server behind a new bundle says "not available", not "we failed"');
});

test('photo 6: a history row never invents a price it was not paid', () => {
  const rewards = section('const loadRewards=async()=>', 'const activityState={items:[],nextCursor:null}');
  assert.match(rewards, /item\?\.consumes_balance===true\?Math\.max\(0,Number\(item\.points_spent\)\|\|0\):0/,
    'a v323 stamp milestone consumes no balance, so it must not print "0 points"');
  assert.match(rewards, /\$\{spent>0\?`<p class="muted small"[^`]*customerPointTotalV103\(spent\)/);
});

test('photo 6: an empty catalogue no longer takes the customer\'s claim history with it', () => {
  const rewards = section('const loadRewards=async()=>', 'const activityState={items:[],nextCursor:null}');
  assert.ok(!code(rewards).includes("if(!rewards.length)return walletSectionEmpty('walletRewards'"),
    'the early return that replaced the whole section is gone');
  assert.match(rewards, /Nothing to claim yet — keep collecting and your reward will appear here\./,
    'the Available panel carries its own empty line instead');
});

test('photo 6: the retired stamp card takes its box with it, and never its reward list', () => {
  assert.ok(!code(app).includes('stampsQuestRetired'),
    'the sentence the owner struck out, and its four locale strings, are gone');
  assert.ok(!app.includes('This stamp card has been retired'));
  const loader = section('const loadStampCardV323=async()=>', 'const loadGrowthOffers=async()=>');
  const migrated = loader.slice(loader.indexOf('if(quest.potMigrated){'));
  assert.ok(migrated.indexOf("card.querySelector('#walletRewards')") < migrated.indexOf('card.remove()'),
    'the reward list is lifted out BEFORE the card that hosts it is removed');
  assert.match(migrated, /insertAdjacentElement\('beforebegin',rewardsHostV422\)/);
  assert.match(migrated, /card\.remove\(\);\s*\n?\s*return;/);
});

/* -------------------------------------------------- the server read behind History ------------- */

test('the history read is scoped by the wallet context, never by an argument', async () => {
  const sql = await readFile(
    new URL('../../db/migrations/20260822_nestly_v422_customer_reward_history.sql', import.meta.url),
    'utf8');
  assert.match(sql, /create or replace function public\.customer_get_reward_history_v422\(\s*\n?\s*p_business_slug text,\s*\n?\s*p_limit integer default 50\s*\n?\s*\)/,
    'the only arguments are a slug and a limit — nothing that could name another customer');
  assert.match(sql, /from app\.v32_customer_wallet_context\(p_business_slug\)/);
  assert.match(sql, /redemption\.business_id = v_context\.business_id/);
  assert.match(sql, /redemption\.client_id = v_context\.client_id/);
  assert.match(sql, /raise exception 'verified customer link required' using errcode = '42501'/);
  /* A redemption the counter took back is not something the customer received. */
  assert.match(sql, /not exists \(\s*\n?\s*select 1\s*\n?\s*from public\.loyalty_redemption_reversals reversal/);
  /* stable = it cannot write, whatever else changes about it. */
  assert.match(sql, /returns jsonb\s*\n?\s*language plpgsql\s*\n?\s*stable\s*\n?\s*security definer/);
  assert.match(sql, /revoke all on function public\.customer_get_reward_history_v422\(text, integer\) from public, anon;/);
  assert.match(sql, /grant execute on function public\.customer_get_reward_history_v422\(text, integer\) to authenticated, service_role;/);
  /* The browser calls it with exactly those two arguments. */
  assert.match(app, /customerRpc\('customer_get_reward_history_v422',\s*\n?\s*\{p_business_slug:businessSlug,p_limit:50\}\)/);
});

/* ======================================================================================
   nestly_v428 — the go-live review's customer-side findings, on the same surfaces.
   Every case below EXECUTES the shipped helper: each one decides what a customer is told
   they may walk in and claim, which is the one class of copy a grep must not be trusted with.
   ====================================================================================== */

test('nestly_v428 item 7: readiness is the server\'s answer, never arithmetic on the balance', () => {
  const { customerRewardProgressMarkupV310 } = harness;
  const line = markup => markup.match(/<p class="muted small">([^<]*)<\/p>/)?.[1] ?? '';

  /* THE DEFECT. A free reward (cost 0) that the server has disabled, ended, tier-locked or
     claim-limited answers available_now:false — and `||cost===0` announced it as ready anyway. */
  const freeButRefused = customerRewardProgressMarkupV310({
    loyalty: { balance: 0 }, reward: { name: 'Free Tote', cost_units: 0, remaining_units: 0, available_now: false }
  });
  assert.doesNotMatch(line(freeButRefused), /ready/i,
    'a zero cost is not a permission — only availability is');

  /* Nor does a cleared threshold speak for the server. */
  const clearedButRefused = customerRewardProgressMarkupV310({
    loyalty: { balance: 77877 }, reward: { name: 'Facial', cost_units: 1000, remaining_units: 0, available_now: false }
  });
  assert.doesNotMatch(line(clearedButRefused), /ready/i);

  // What the server DOES allow is still announced, and the distance sentence still counts.
  const allowed = customerRewardProgressMarkupV310({
    loyalty: { balance: 1000 }, reward: { name: 'Facial', cost_units: 1000, remaining_units: 0, available_now: true }
  });
  assert.match(line(allowed), /Facial/);
  const earning = customerRewardProgressMarkupV310({
    loyalty: { balance: 400 }, reward: { name: 'Facial', cost_units: 1000, remaining_units: 600, available_now: false }
  });
  assert.match(line(earning), /600/, 'the "N to go" arithmetic is what arithmetic is for');
});

test('nestly_v428 item 6: two gifts on ONE stamp slot are a choice, not two rewards', () => {
  const { customerStampChooseOneSlotV428: chooseOne } = harness;
  const gift = (name, slot) => ({ customer_name: name, cost_points: slot, redemption_kind: 'catalog_reward' });

  /* public.stamp_milestone_claims is unique on (business, client, programme, cycle, slot) — one
     gift per milestone per card (v323) — and a milestone's slot IS its cost. Two claimable gifts
     sharing a cost are therefore one choice, however the count reads. */
  assert.equal(chooseOne([gift('Cake', 8), gift('Coffee', 8)], 'stamps'), true);
  assert.equal(chooseOne([gift('Cake', 8), gift('Coffee', 5)], 'stamps'), false,
    'different slots are independent claims');
  assert.equal(chooseOne([gift('Cake', 8)], 'stamps'), false);

  /* The stamps gate is load-bearing, not decoration: two POINTS rewards that happen to cost the
     same are genuinely independent, and a customer with the balance may take both. */
  assert.equal(chooseOne([gift('Cake', 8), gift('Coffee', 8)], 'points'), false);
  assert.equal(chooseOne([gift('Cake', 8), gift('Coffee', 8)], undefined), false);

  // A classic points redemption carries no slot and can never make the card look like a choice.
  assert.equal(chooseOne([
    { cost_points: 0, redemption_kind: 'classic_points' },
    { cost_points: 0, redemption_kind: 'classic_points' }
  ], 'stamps'), false);
});

test('nestly_v428 item 6: the tile says how many the customer may TAKE, not how many exist', () => {
  const { customerRewardReadyCountApplyV397 } = harness;
  const node = () => ({ textContent: '', dataset: { rewardReadyFallbackV397: 'Collect stamps here' } });
  const root = target => ({ querySelectorAll: () => [target] });

  const choice = node();
  customerRewardReadyCountApplyV397(2, root(choice), { chooseOneV428: true });
  assert.equal(choice.textContent, 'Choose 1 reward');

  // Independent rewards keep the count — two really are claimable.
  const independent = node();
  customerRewardReadyCountApplyV397(2, root(independent));
  assert.equal(independent.textContent, '2 rewards ready');

  /* Unchanged: a firm that loses its last claimable reward between renders falls back to what the
     renderer painted, never to "0 rewards ready". */
  const none = node();
  customerRewardReadyCountApplyV397(0, root(none), { chooseOneV428: true });
  assert.equal(none.textContent, 'Collect stamps here');
});

test('nestly_v428 item 6: the Available panel says which part of the count the customer gets', () => {
  const rewards = code(section('const loadRewards=async()=>', 'const activityState={items:[],nextCursor:null}'));
  /* One derivation feeds the pill, the tile subtitle and the list, so the three cannot disagree. */
  assert.match(rewards, /const claimableRewardsV422=rewards\.filter\(item=>item\.action_key&&customerRewardCanRedeem\(item,redemptionEnabled\)\);\s*\r?\n\s*const readyCountV397=claimableRewardsV422\.length;/);
  assert.match(rewards, /const chooseOneSlotV428=customerStampChooseOneSlotV428\(claimableRewardsV422,loyalty\.unit\);/);
  assert.match(rewards, /customerRewardReadyCountApplyV397\(readyCountV397,heroRootV397,\{chooseOneV428:chooseOneSlotV428\}\)/);
  assert.match(rewards, /data-rewards-chooseone-v428>Choose 1 — staff will scan the one you pick\./);
  // The count itself stays: two ARE on offer, and the customer picks between them.
  /* nestly_v429 (C): and it now also counts the v427 entitlements painted below the catalogue
     cards — a welcome gift or bring-back voucher the counter already owes them is claimable, so
     leaving it out would make this number an undercount of the same panel. */
  assert.match(rewards, /data-rewards-tab-v422="available">Available\$\{claimableRewardsV422\.length\+entitlementsV429\.length\?` \(\$\{claimableRewardsV422\.length\+entitlementsV429\.length\}\)`:''\}/);
});

test('nestly_v428 item 9: a stamps balance never prints as points because the unit was missed', () => {
  const { customerHomeBusinessBalanceV345, customerProgrammeDirectoryMetricV346 } = harness;

  /* THE DEFECT (Cubbly, go-live review): an actionable wallet card carries {balance, unit} and no
     programme stack, so the kind resolver fell through to its 'points' default and 758 stamps were
     printed as "758 pts". The payload's own unit is read first now. */
  const stampsCard = { loyalty: { balance: 758, unit: 'stamps' } };
  assert.equal(customerHomeBusinessBalanceV345(stampsCard), '',
    'v422: a stamps card contributes no balance figure here — but it must be RECOGNISED as one');
  assert.equal(customerProgrammeDirectoryMetricV346(stampsCard), '');

  // Points are untouched, with or without the field.
  assert.equal(customerHomeBusinessBalanceV345({ loyalty: { balance: 758, unit: 'points' } }), '758 pts');
  assert.equal(customerHomeBusinessBalanceV345({ loyalty: { balance: 758 } }), '758 pts',
    'a server that does not send the unit yet renders exactly as it did before');
});
