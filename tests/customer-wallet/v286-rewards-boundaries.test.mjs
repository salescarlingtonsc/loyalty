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
  assert.match(rewards, /Redemption can’t be checked right now/);
  assert.match(rewards, /id="walletRewardsRedemptionRetry"/,
    'the section needs the same labelled retry every other wallet section offers');
  assert.match(appJs, /if\(\$\('walletRewardsRedemptionRetry'\)\)\$\('walletRewardsRedemptionRetry'\)\.onclick=loadRewards;/,
    'the retry button must actually re-run the load');
});

test('the QR lede is suppressed when no QR can be issued', () => {
  assert.match(rewards, /\$\{redemptionUncheckedV286\s*\r?\n?\s*\?`<div class="wallet-section-head" data-rewards-redemption-unchecked/,
    'the failure banner replaces the lede rather than sitting beside it');
  /* v337: a "Your rewards" title now precedes the lede (the section restyled into a horizontal
     carousel), so the lede itself is matched without anchoring to the very start of the branch. */
  assert.match(rewards,
    /:`<div class="customer-rewards-carousel-head-v337">[\s\S]*?<p class="muted small customer-programme-rewards-lede">Pick a reward, then show its QR at the counter/,
    'the "show its QR at the counter" promise sits in the else branch — printed only when redemption was checked');
});

test('no card claims counter availability the page could not verify', () => {
  /* nestly_v422 (owner photo 6): this guarantee stopped being TEXTUAL and became STRUCTURAL.
     v286 kept every reward on the list and relabelled "Available at counter" to "Redemption can't
     be checked right now". The list now holds ONLY what customerRewardCanRedeem approves, and that
     predicate's first clause is `redemptionEnabled!==true` — so when the redemption check failed
     there is no card to mislabel at all, and the panel says the check failed instead. That is a
     stronger form of the same promise, so the local copy and the override it corrected are gone.
     What must not regress: the shared constant still carries the honest default (the hero swipe
     pages read it), and nothing anywhere mutates that shared constant. */
  assert.match(rewards, /const claimableRewardsV422=rewards\.filter\(item=>item\.action_key&&customerRewardCanRedeem\(item,redemptionEnabled\)\)/,
    'the list is exactly what the counter will honour');
  assert.match(appJs, /function customerRewardCanRedeem\(reward,redemptionEnabled\)\{\s*if\(redemptionEnabled!==true/,
    'an unverified redemption check makes every reward unclaimable, so no card renders');
  assert.match(rewards, /redemptionUncheckedV286\s*\?'We could not check this business’s redemption settings/,
    'and the panel says so rather than showing an empty list');
  assert.doesNotMatch(rewards, /availability\.available_at_counter=/,
    'no card is left to relabel');
  /* The override must never have mutated the SHARED constant — doing that would leak one render's
     "could not check" wording into every later render and into the hero page. */
  assert.doesNotMatch(appJs,/CUSTOMER_REWARD_AVAILABILITY_COPY_V399\.available_at_counter\s*=/);
  assert.match(appJs,/CUSTOMER_REWARD_AVAILABILITY_COPY_V399=\{[^}]*available_at_counter:'Available at counter'/s);
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
  /* v326 (owner mockup: cover photo, logo, name and Book now on one row; phone/address of their
     own beneath): "Address, phone and offers ›" and the responsive hint-long/hint-short swap
     moved out of the identity button entirely — the contact area below the cover photo now has
     its own room for that text at every width, so the squeeze-behind-the-name affordance this
     test used to guard no longer exists. The tier label survives, just without the trailing
     "· " it used to need before a hint span that is no longer there. */
  const merchant = section(appJs, 'function customerMerchantExperienceMarkupV95', 'function actionableWalletCardMarkup');
  const identity = section(merchant, '<button class="customer-programme-identity"', '</button>');
  /* v327 (owner: "clicked tier > auto scroll to tier below"): the tier label moved out of the
     identity button entirely into its own sibling <button data-tier-scroll-v327> — nesting a
     control inside another control is invalid HTML, and it needed to be its own click target. */
  assert.match(merchant, /\$\{hasTier&&currentTierLabel\?`<button type="button" class="customer-programme-identity-hint customer-programme-tier-jump-v327" data-tier-scroll-v327>\$\{esc\(currentTierLabel\)\}<\/button>`:''\}/,
    'the tier label survives, now as its own clickable button');
  assert.doesNotMatch(identity, /customer-programme-identity-hint/,
    'the tier hint is no longer nested inside the identity button');
  assert.doesNotMatch(merchant, /customer-programme-identity-hint-long|customer-programme-identity-hint-short/,
    'the width-swapped hint spans moved out of the identity button with the redesign');
  /* v337 (owner mockup "photo 1"): the header contact area's "Address, phone and offers ›" link
     became an Address/Call segment pair (plus a sibling Book now segment) — same click paths
     (data-company-detail / tel: / the existing booking href), restyled into three segments. */
  assert.match(merchant, /customer-programme-contact-row-v337/,
    'the affordance lives in the header contact row now, not squeezed behind the name');
});
