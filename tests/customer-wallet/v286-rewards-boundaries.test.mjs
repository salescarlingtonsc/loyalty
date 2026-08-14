import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const indexHtml = await read('app/index.html');
const appJs = await read('app/app.js');

function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

const rewards = section(appJs, '  const loadRewards=async()=>{', '  const loadActivity=async(');

/* ---------------------------- 1 · the rewards section that went read-only without saying so */

test('a failed actions read is named, not silently swallowed', () => {
  assert.match(rewards, /const redemptionUncheckedV286=!!actionsResult\.error;/,
    'the failure of customer_get_business_actions_v89 must be carried into the render');
  /* v322: the same sentence, routed through ct() so it is not English on a Tamil phone. */
  assert.match(rewards, /ct\('rewardsUncheckedTitle'\)/);
  assert.match(appJs, /rewardsUncheckedTitle:'Redemption can’t be checked right now'/);
  assert.match(rewards, /id="walletRewardsRedemptionRetry"/,
    'the section needs the same labelled retry every other wallet section offers');
  assert.match(appJs, /if\(\$\('walletRewardsRedemptionRetry'\)\)\$\('walletRewardsRedemptionRetry'\)\.onclick=loadRewards;/,
    'the retry button must actually re-run the load');
});

test('the QR lede is suppressed when no QR can be issued', () => {
  assert.match(rewards, /\$\{redemptionUncheckedV286\s*\r?\n?\s*\?`<div class="wallet-section-head" data-rewards-redemption-unchecked/,
    'the failure banner replaces the lede rather than sitting beside it');
  assert.match(rewards,
    /:`<p class="muted small customer-programme-rewards-lede">\$\{esc\(ct\('rewardsLede'\)\)\}/,
    'the "show its QR at the counter" promise sits in the else branch — printed only when redemption was checked');
});

test('no card claims counter availability the page could not verify', () => {
  /* v322: the state moved onto the row's chip, where the row states its own status. Unchecked
     redemption still cannot print a counter-availability claim. */
  assert.match(rewards,
    /\(redemptionUncheckedV286&&r\.availability==='available_at_counter'\)\?ct\('rewardOffChip'\)/,
    '"Available at counter" must not survive a redemption check that never happened');
  /* The order still has to read: state map, then the correction, then the row that prints it. */
  const map = rewards.indexOf("available_at_counter:ct('rewardReadyChip')");
  const guard = rewards.indexOf("(redemptionUncheckedV286&&r.availability==='available_at_counter')");
  const row = rewards.indexOf('customer-reward-row-chip-v322');
  assert.ok(map > 0 && guard > map && row > guard,
    'the override sits between the map it corrects and the row that reads it');
});

/* ---------------------------- 2 · the wallet read that was fetched and thrown away */

test('customer_get_wallet feeds the programme switcher instead of being discarded', () => {
  const detail = section(appJs, "  const args={p_business_slug:businessSlug};", '  const unavailableBusinessId=');
  assert.match(detail, /programmeResult\]=await Promise\.all\(\[/, 'the third read is still issued');
  assert.match(detail, /if\(!programmeCards\.length&&!programmeResult\.error\)\{/,
    'an empty programmeCards must fall back to the wallet read already paid for');
  assert.match(detail,
    /programmeCards=Array\.isArray\(programmeResult\.data\)\?programmeResult\.data\s*\r?\n?\s*:\(Array\.isArray\(programmeResult\.data\?\.cards\)\?programmeResult\.data\.cards:\[\]\);/,
    'both the array and {cards:[...]} shapes are accepted');
  const use = detail.indexOf('programmeCards=Array.isArray(programmeResult.data)');
  const id = detail.indexOf('customerBusinessIdV103({');
  assert.ok(use > 0 && id > use,
    'the fallback must run BEFORE customerBusinessIdV103, whose third candidate it restores');
});

/* ---------------------------- 3 · the mobile header that lost its only affordance */

test('the company-details affordance and tier survive at 390px', () => {
  assert.doesNotMatch(indexHtml, /@media\(max-width:560px\)\{\.customer-programme-identity-hint\{display:none\}/,
    'hiding the whole hint left the header with no cue that it opens the company sheet');
  assert.match(indexHtml, /\.customer-programme-identity-hint-short\{display:none\}/,
    'the short label is desktop-hidden by default');
  assert.match(indexHtml,
    /@media\(max-width:560px\)\{\.customer-programme-identity-hint-long\{display:none\}\.customer-programme-identity-hint-short\{display:inline\}/,
    'at 560px the long wording gives way to the short label — the affordance stays visible');
  const merchant = section(appJs, 'function customerMerchantExperienceMarkupV95', 'function actionableWalletCardMarkup');
  const identity = section(merchant, '<button class="customer-programme-identity"', '</button>');
  assert.match(identity, /\$\{hasTier&&currentTierLabel\?`\$\{esc\(currentTierLabel\)\} · `:''\}/,
    'the tier label sits outside the width-swapped spans, so mobile keeps it');
  assert.match(identity, /<span class="customer-programme-identity-hint-long">Address, phone and offers ›<\/span>/);
  assert.match(identity, /<span class="customer-programme-identity-hint-short">Details ›<\/span>/);
});
