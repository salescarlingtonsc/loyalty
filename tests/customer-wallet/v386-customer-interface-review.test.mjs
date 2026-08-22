/* v386 — the ten annotated customer screens (owner, 2026-08-17).
 *
 * Each assertion fails against the pre-v386 source:
 *  1. (photo 3) "Claim reward" scrolled to #walletRewards, which v347/v348 moved into a hidden
 *     shortcut page — scrollIntoView on a hidden element does nothing, so the button was inert.
 *  2. (photos 5+10) A paused programme kept a card announcing it was paused.
 *  3. (photos 5+10) "Tier benefits" and "Points & gifts" opened ONE section, so each showed the
 *     other's cards.
 *  4. (photo 6) The tier ladder shipped collapsed.
 *  5. (photo 10) The Points & gifts balance was suppressed on the one screen named after it, and
 *     the expiry the server already returns was never shown there.
 *  6. (photo 4) "Earn more points → Visit and spend here" told the customer nothing.
 *  7. (photo 1) The offer card's business name was hidden by a .muted catch-all, and the ready
 *     card restated its own reward count as a business count.
 *  8. (photo 2) The company sheet listed offers already on the page behind it and offered to
 *     open the page the customer was standing on; the phone number had no glyph; other branches
 *     were unreachable.
 *  9. (photo 7) The hero printed one shape for every firm — "0 points" at a tiers-only business.
 * 10. (photo 8) One message was a card with three buttons under two stacked explanations.
 * 11. (photo 9) An offer whose CTA is "Book now" had no way into its details at all.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');
const indexHtml=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');

test('photo 3: Claim reward opens the rewards shortcut page instead of scrolling to a hidden node',()=>{
  /* nestly_v395 moved this out of renderCustomerWallet into wireCustomerClaimRewardV395 so both
     surfaces that render the [data-claim-reward-scroll-v337] contract get wired — querySelector
     was SINGULAR, so whichever of the banner and the hero came second in the DOM was a button that
     genuinely did nothing. Same route, same tile, same two-frame wait. */
  const handler=app.slice(app.indexOf('function wireCustomerClaimRewardV395'),app.indexOf('function customerClaimableRewardBannerMarkupV337'));
  assert.match(handler,/querySelectorAll\('\[data-claim-reward-scroll-v337\]'\)/,
    'EVERY button carrying the contract is wired, not just the first one on the page');
  assert.match(handler,/data-business-shortcut-v347="points"\],\[data-business-shortcut-v347="rewards"/,
    'it reuses the tile the customer could have tapped, not a second claim path');
  assert.match(handler,/rewardsTile\.click\(\)/);
  assert.match(handler,/customerBusinessShortcutPageV348'\)\?\.hidden!==false/,
    'only when the shortcut page is not already open');
  assert.match(handler,/requestAnimationFrame\(\(\)=>requestAnimationFrame\(scrollToRewards\)\)/,
    'the scroll waits for the page it just opened to be laid out');
  assert.match(handler,/if\(scrollToRewards\(\)\)return;/);
  assert.match(handler,/toast\('Your rewards are still loading\. Try again in a moment\.'\)/,
    'with no rewards surface at all it says so rather than absorbing the tap');
  assert.match(app,/wireCustomerClaimRewardV395\(\$\('walletBody'\)\);/,
    'and renderCustomerWallet still calls it');
});

test('photos 5+10: a paused programme paints no card at all',()=>{
  const stack=app.slice(app.indexOf('function customerProgrammeStackV310'),app.indexOf('function customerPointsHeroVisibleV337'));
  assert.match(stack,/const cardPausedV386=kind=>entries\[kind\]\?\.active===false/);
  assert.match(stack,/show\.stamps&&!cardPausedV386\('stamps'\)/);
  assert.match(stack,/show\.points&&!cardPausedV386\('points'\)/);
  assert.match(stack,/rewardsHost&&!\(show\.stamps&&!cardPausedV386\('stamps'\)\)&&!\(show\.points&&!cardPausedV386\('points'\)\)/,
    'the gifts host survives a stack whose accruing cards are all paused');
});

test('photos 5+10: each shortcut shows only the cards that belong to it',()=>{
  const open=app.slice(app.indexOf('function openCustomerBusinessShortcutPageV348'),app.indexOf('function closeCustomerBusinessShortcutPageV348'));
  assert.match(open,/keepForActionV386=\{tiers:\['tiers'\],points:\['stamps','points'\],rewards:\['stamps','points'\]\}\[action\]/);
  assert.match(open,/hiddenByShortcutV386\.push\(card\)/);
  assert.match(open,/hiddenByShortcutV386\.forEach\(node=>\{node\.hidden=false\}\)/,
    'and restores them on close, so the main page is unchanged');
  assert.match(open,/action==='tiers'\)target\.querySelectorAll\('\[data-points-explainer\]'\)/,
    'the points explainer still follows the points half');
  /* nestly_v446 (REG-002) re-pinned. v386 hid the section's own group head for the TIERS action
     only, because that is where it had been noticed; the stamp-card tile therefore opened a page
     headed "Rewards" over a section headed "Rewards". The head is redundant on this page whatever
     tile opened it — the page prints the title in its own h1 — so it is hidden unconditionally. */
  assert.match(open,/target\.querySelectorAll\('\.customer-business-group-head-v346'\)\.forEach/,
    'and the section group head is hidden for every action, not only tiers');
});

test('photo 6: the tier ladder ships open',()=>{
  assert.match(app,/<details class="customer-tier-ladder" open>/);
});

test('photo 10: Points & gifts shows the balance it is named after, and when it expires',()=>{
  assert.match(app,/function customerPointsExpiryLineV386/);
  /* The helper is declared between the points panel and the tier panel deliberately: the v289 G4
     harness evals exactly that span to exercise customerProgrammePointsPanelV230 in isolation,
     and a helper outside it would be an undefined reference there. */
  const line=app.slice(app.indexOf('function customerPointsExpiryLineV386'),app.indexOf('function customerProgrammeTierPanelV230'));
  assert.match(line,/expiry\?\.expiring_units/);
  assert.match(line,/expiry\?\.next_expiry_at/);
  assert.match(line,/if\(!units\|\|!at\)return ''/,'no invented date when the server gives none');
  assert.match(app,/customerPointsExpiryLineV386\(\{expiry,loyalty,presentation\}\)/);
  assert.match(app,/suppressPointsCardV337:false,suppressRewardFactV337:rewardBannerVisibleV338,deferReferralSlotV339:true,expiry:actionableCard\?\.expiry\|\|null/,
    'the collapsed profile stops suppressing the balance, because its hero is hidden behind the sub-page');
});

test('photo 4: the "Earn more points" card is gone, function and call sites',()=>{
  assert.doesNotMatch(app,/customerEarnMorePointsMarkupV339/);
  assert.doesNotMatch(app,/Visit and spend here/);
});

test('photo 1: the offer card names its business, and the ready card drops the business count',()=>{
  assert.match(indexHtml,/\.customer-home-offer-copy>\.muted\{display:none\}/,
    'direct children only — the nested business-name span must survive');
  /* Un-hiding it was not enough: in flow it landed under the absolutely-positioned
     "Ends in N days" pill, which painted straight over it.
     nestly_v395 (owner photo 2, "move here" drawn to the right of the avatar): v386's order:-2
     hoisted the name to the first line of the copy but left it IN FLOW, while the 46px avatar is
     position:absolute at top:-30px — so the name began exactly where the avatar ended and read as
     a caption UNDER it, not beside it. The row is pinned to the avatar's own box now and the
     avatar rides inside it as a plain flex child, which is what puts the two on one line.
     Measured after the change at 390/768/1024: logo and row share top and height, and
     elementFromPoint at the name's centre returns the name, not the countdown. */
  assert.match(indexHtml,/\.customer-home-offer-business\{position:absolute!important;top:-30px;left:10px;right:10px;z-index:2;margin:0;min-height:46px;height:46px;display:flex;align-items:center;gap:10px/);
  assert.match(indexHtml,/\.customer-home-offer-logo\{position:static;top:auto;left:auto;flex:0 0 auto;width:46px;height:46px/,
    'the avatar sits IN the row rather than being positioned against it');
  assert.match(indexHtml,/\.customer-home-offer-copy\{position:relative;/,
    'the copy block is the positioning context at every width, not only under the <=720px layer');
  assert.match(indexHtml,/\.customer-home-offer-copy h3\{order:0;flex:0 0 auto\}/);
  assert.match(indexHtml,/\.customer-home-offer-copy\{position:relative;min-height:auto;height:136px/,
    'and the card gained the room for name + two title lines + the countdown line below them');
  assert.doesNotMatch(indexHtml,/\.customer-home-offer-copy \.muted:not\(\.customer-home-offer-business\)\{display:none\}/);
  const summary=app.slice(app.indexOf('function customerHomeSummaryV343'),app.indexOf('function customerHomeBusinessStatusV345'));
  assert.doesNotMatch(summary,/across \$\{esc\(customerPointTotalV103\(businessCount\)\)\}/);
  assert.doesNotMatch(summary,/const businessCount=/,'the count is not computed either');
});

test('photo 2: the company sheet is company details, with a phone glyph and every branch',()=>{
  const sheet=app.slice(app.indexOf('function showCustomerBusinessDetailV178'),app.indexOf('function customerBranchContactLinesV386'));
  assert.doesNotMatch(sheet,/customer_get_promotions_v155/);
  assert.doesNotMatch(sheet,/data-business-detail-nav/);
  assert.match(sheet,/data-business-branches-v386/);
  assert.match(sheet,/\.slice\(1\)/,'branches\[0\] is the default branch already printed above');
  const lines=app.slice(app.indexOf('function customerBranchContactLinesV386'));
  assert.match(lines.slice(0,900),/CUI\.icon\('phone',\{size:16\}\)/);
  assert.doesNotMatch(lines.slice(0,900),/CUI\.icon\('mail'/,'there is no envelope glyph; an unknown name falls back to INFO');
});

test('photo 7: the hero takes its shape from the business’s own programme spine',()=>{
  const mode=app.slice(app.indexOf('function customerBusinessHeroModeV386'),app.indexOf('function customerBusinessRelationshipSummaryV346'));
  assert.match(mode,/if\(live\('points'\)\)return 'points'/);
  assert.match(mode,/if\(live\('stamps'\)\)return 'stamps'/);
  assert.match(mode,/if\(live\('tiers'\)\)return 'tiers'/);
  const hero=app.slice(app.indexOf('function customerBusinessRelationshipSummaryV346'),app.indexOf('function customerBusinessSecondaryMarkupV346'));
  assert.match(hero,/customerProgrammeStampRingsV310\(balance,stampTargetV386\)/,'the rings are the existing renderer, not a new one');
  /* nestly_v422: those rings are now the FIRST PAINT only. They are sized by one reward's
     cost_units, which is not the card's length, so loadStampCardV323 swaps in the real card
     (customerHeroStampCardV422) as soon as the server's slots and milestones arrive. The slot is
     asserted here because it is the contract between the two. */
  assert.match(hero,/data-hero-stamp-slot-host-v422/,'the stamps figure is a slot the v323 read fills');
  assert.match(hero,/customer-business-tier-meter-v386/);
  /* v393 adds one clause: with NO tier from either source there is no tier figure to sit above,
     so the hero falls back to its plain-number form and the reward lines come back with it. */
  /* nestly_v422 (owner photo 8) adds STAMPS to that rule for a different reason: the hero draws the
     whole stamp card now, and that card carries its own "Next available Reward: X" line, so the two
     prose lines above and below it were the same sentence a second and third time. */
  assert.match(hero,/const showRewardLinesV386=\(modeV386!=='tiers'\|\|!tierBlockV393\|\|rewardReady\)&&modeV386!=='stamps'/,
    'a tiers-only firm gets no sentences about a reward ladder it does not run, and stamps says it once');
  assert.match(hero,/const liveTierV393=\(loyalty&&typeof loyalty\.tier==='object'&&loyalty\.tier\)\?loyalty\.tier:null/,
    'v393: the server tier snapshot is the first source, not a derived one');
  assert.match(hero,/Math\.round\(tierMetricV393\/tierNextThresholdV393\*100\)/,
    'the gold track is metric over the NEXT rung threshold, never a fabricated percentage');
  assert.match(hero,/tierRemainingV386=liveTierV393\s*\n?\s*\?Math\.max\(0,Number\(tierNextV386\?\.remaining\|\|0\)\)/,
    'the "X to go" line is the server\'s own remaining distance');
  assert.match(hero,/:'You are at the top tier'/,'no track is invented for the top rung');
  assert.match(hero,/data-hero-mode-v386="\$\{esc\(modeV386\)\}"/);
  assert.match(indexHtml,/\.customer-business-stamp-figure-v386 \.customer-programme-stamp-rings\{display:grid/);
});

test('photo 8: one message is one row, and the settings live behind the gear',()=>{
  const inbox=app.slice(app.indexOf('async function renderCustomerInAppInbox'),app.indexOf('function renderWorkspaceAccessUnavailable'));
  assert.match(inbox,/customer-inbox-row-v386/);
  assert.match(inbox,/customer-inbox-avatar-v386/);
  assert.match(inbox,/customer-inbox-row-when-v386/);
  assert.doesNotMatch(inbox,/Mark \$\{state==='unread'\?'read':'unread'\}/,'the third competing button is gone');
  assert.doesNotMatch(inbox,/customer-inbox-group/,'every row names its own business, so the group heading repeats it');
  /* nestly_v417 (owner, photo 9: the gear ringed — "remove this button"). The toggle is gone.
     What it hid is NOT: the panel it opened held this business's inbox-reminder preferences and
     the device switch, and the gear was their only door, so the panel is simply always rendered —
     below the messages it governs. That is what is asserted instead. */
  assert.doesNotMatch(inbox,/customerInboxSettingsToggleV386/);
  assert.match(inbox,/id="customerInboxSettingsV386" class="customer-inbox-settings-v386">/,
    'always open — no hidden attribute and no toggle');
  assert.match(inbox,/customerInAppInboxPreferences/,'the reminder preferences survive the gear');
  assert.match(inbox,/customerInboxDeviceSlotV386/);
  assert.match(inbox,/deviceSlotV386\.appendChild\(deviceSectionV386\)/,
    'the device switch is MOVED, keeping the id its already-bound control was wired by');
  assert.doesNotMatch(app,/<h1>Messages<\/h1><p class="muted">Customer-safe updates grouped by your separate business programmes\./);
  assert.match(indexHtml,/\.customer-inbox-row-main-v386\{/);
});

test('photo 9: the offer card itself opens the detail sheet, and the address gets its own line',()=>{
  assert.match(app,/document\.querySelectorAll\('\.customer-promotion-card\[data-promotion-id\]'\)/);
  assert.match(app,/if\(event\.target\.closest\('a,button,summary,input,select,textarea,label'\)\)return/,
    'the card’s own controls keep their behaviour');
  assert.match(app,/if\(detailsButton\)return detailsButton\.click\(\)/,'one code path, one analytics event');
  assert.match(app,/data-company-address-line-v386/);
  assert.match(indexHtml,/\.customer-business-address-line-v386\{/);
});

/* v389 (owner sent a screenshot of the failed-load card asking "why failed to load?"). */
test('v389: a failed wallet load says which transport code it failed with',()=>{
  const retry=app.slice(app.indexOf('function customerLoadReferenceV389'),app.indexOf('function walletDate'));
  assert.match(retry,/console\.error\('\[peekaa\] wallet load failed'/,
    'the full error reaches the console for whoever holds the device');
  assert.match(retry,/Reference: <code>/,'and a short reference reaches the screen');
  assert.match(retry,/\/\^\[A-Za-z0-9_\]\{2,12\}\$\//,'only a code-shaped string is ever printed');
  assert.match(retry,/return 'network'/,'a request that never reached the database says so');
  assert.doesNotMatch(retry,/error\.message\}|esc\(error\.message/,
    'never the server message — it can name internals');
  const ref=app.slice(app.indexOf('function customerLoadReferenceV389'),app.indexOf('function renderCustomerWalletRetry'));
  assert.match(ref,/if\(!error\)return ''/,'no reference line when there is no error object');
});

/* v390 (owner: "maybe because i was out of credit?"). A phone with no data left renders the
   cached shell and fails the data call — the customer must not be told the BUSINESS is broken. */
test('v390: a dead connection says so, and does not blame the business',()=>{
  const off=app.slice(app.indexOf('function customerWalletOfflineV390'),app.indexOf('function renderCustomerWalletRetry'));
  assert.match(off,/globalThis\.navigator\?\.onLine===false/);
  assert.match(off,/customerAuthFailureKindV289\(error\)==='network'/,
    'reuses the existing classifier rather than a second opinion about what offline means');
  const retry=app.slice(app.indexOf('function renderCustomerWalletRetry'),app.indexOf('function walletDate'));
  assert.match(retry,/You appear to be offline/);
  assert.match(retry,/Nothing you have earned is affected/,
    'the one thing a customer actually worries about when their wallet will not load');
  assert.match(retry,/const offline=!expired&&customerWalletOfflineV390\(error\)/,
    'expiry still wins — it has its own Sign in action');
});

/* v392 (owner, 2026-08-19): "for the photo i need it to be fitting to the screen as much as
   possible" and "before book now, should be view more then book now after reading". Asked
   directly whether cropping could win, the owner reaffirmed the V173/V371 no-crop rule. */
test('v392: the offer artwork is shown large and whole, never cropped',()=>{
  const rail=indexHtml.slice(indexHtml.indexOf('.customer-reward-offer-page-v339 .customer-promotion-card{'));
  assert.match(rail.slice(0,700),/flex-direction:column/,
    'the swipe card is photo-led again, not an 84px thumbnail row');
  assert.doesNotMatch(rail.slice(0,700),/flex:0 0 84px/);
  assert.match(rail.slice(0,700),/max-height:46vh;object-fit:contain/,
    'bounded so the card stays about half a screen, and contained so nothing is cut off');
  /* nestly_v417: the owner reversed that ruling (photos 1/3/4) — cards crop to one shape so two
     offers look the same size. The full-page offer view above still contains, which is the line
     directly before this one and is what keeps the poster intact where it matters. */
  assert.match(indexHtml,/\.customer-promotion-card-media img\{[^}]*object-fit:cover/);
  const detail=indexHtml.match(/\.customer-offer-detail-media\{[^}]*\}/)[0];
  assert.match(detail,/background:transparent/,
    'a transparent frame is what removes the bars — a fit-content frame collapses against the image');
  assert.match(indexHtml,/\.customer-offer-detail-media img\{[^}]*max-height:72vh/);
  assert.doesNotMatch(indexHtml,/\.customer-offer-detail-media img\{[^}]*max-height:420px/);
});
