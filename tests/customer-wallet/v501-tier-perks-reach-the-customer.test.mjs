/* nestly_v501 — the tier perk the owner configured reaches the customer who earned it.
 *
 * Owner, 2026-08-25 (photo 1): "it shows 20% discount once per month. but the rewards did not land
 * on customer view - they should see that reward and redeem it (with qrcode) or business and
 * redeem for them like a typical rewards - nothing new" and "since it is monthly rewards - it will
 * expire by end of month".
 *
 * The perk was countable and issuable the whole time — every tier-benefit reader in the codebase
 * was a STAFF reader, so the person who earned it could not see it. The server half is proved
 * against production by db/tests/v501_customer_sees_tier_benefits.sql (8/8, rolled back). These
 * pin the browser half, and they EXECUTE the shipped renderers rather than grepping for them.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');
const indexHtml = await readFile(new URL('../../app/index.html', import.meta.url), 'utf8');

const block = (start, end) => {
  const i = app.indexOf(start);
  assert.ok(i >= 0, `missing block: ${start}`);
  const j = app.indexOf(end, i);
  assert.ok(j > i, `missing end marker for ${start}`);
  return app.slice(i, j + end.length);
};

const esc = v => String(v ?? '').replace(/[&<>"]/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const harness = (() => {
  const src = [
    block('function customerTierPerkLastDayV501(', '\n}'),
    block('const CUSTOMER_TIER_PERK_WINDOW_V501=', '});'),
    block('function customerTierPerkWindowNounV501(', '\n}'),
    block('function tierPerkHeadingV501(', '\n}'),
    block('    const tierPerkCardV501=perk=>{', '\n    };')
  ].join('\n');
  const scope = {
    esc,
    CUI: { icon: name => `<svg data-icon="${name}"></svg>` },
    customerPointTotalV103: v => String(v),
    walletDate: v => new Date(v).toLocaleString('en-SG',
      { timeZone: 'Asia/Singapore', dateStyle: 'medium' })
  };
  const names = Object.keys(scope);
  return new Function(...names, `${src}
    return {card:tierPerkCardV501,lastDay:customerTierPerkLastDayV501,
            noun:customerTierPerkWindowNounV501,heading:tierPerkHeadingV501};`
  )(...names.map(n => scope[n]));
})();

const goldPerk = {
  benefit_id: 'b-1', tier_label: 'Gold', sentence: '20% off — 1 per month',
  remaining: 1, limit_period: 'month', period_ends_at: '2026-09-01T00:00:00+08:00',
  claimable_now: true, blocked_reason: null
};

test('v501 the perk card says what it is, what is left, and when it lapses', () => {
  const html = harness.card(goldPerk);
  assert.match(html, /20% off — 1 per month/, 'the server sentence, verbatim');
  assert.match(html, /Gold perk/, 'the tier it came from');
  assert.match(html, /1 left this month/, 'what remains in THIS window');
  assert.match(html, /data-customer-tier-perk-v501="b-1"/);
  assert.match(html, /data-tier-perk-remaining-v501="1"/);
});

test('v501 a monthly perk prints the LAST USABLE DAY, not the instant it lapses', () => {
  /* THE OFF-BY-ONE. The server returns the instant the window CLOSES — 1 Sep 00:00 for August.
     Printing that verbatim would promise a day the counter will not honour, because the allowance
     has already reset by then. */
  const html = harness.card(goldPerk);
  assert.match(html, /Use by 31 Aug 2026/,
    'a perk good "for August" must read 31 Aug, never 1 Sep');
  assert.doesNotMatch(html, /Use by 1 Sep/);
  assert.equal(harness.lastDay('2026-09-01T00:00:00+08:00').slice(0, 10), '2026-08-31');
  assert.equal(harness.lastDay('not a date'), '', 'an unparseable date prints no deadline at all');
});

test('v501 an unlimited perk claims no deadline and no dwindling count', () => {
  const html = harness.card({
    benefit_id: 'b-2', tier_label: 'Diamond', sentence: 'Free coffee',
    remaining: null, limit_period: 'ever', period_ends_at: null,
    claimable_now: true, blocked_reason: null
  });
  assert.match(html, /No limit — use it whenever you visit\./);
  assert.doesNotMatch(html, /Use by/, 'nothing that never lapses may print a lapse date');
  assert.doesNotMatch(html, /data-tier-perk-remaining-v501/);
});

test('v501 the card promises the counter, not a QR button it does not have', () => {
  /* A perk is applied by staff once they have the customer on screen — which they get from the
     member QR this same wallet already shows. Drawing a redeem QR here would be a button that
     leads nowhere, the same reasoning v429 applied to granted entitlements. */
  const html = harness.card(goldPerk);
  assert.match(html, /Show your member QR at the counter — staff apply it to your bill\./);
  assert.doesNotMatch(html, /data-customer-redeem/, 'no redemption-intent button on a perk card');
});

test('v501 the window noun and the heading read as English, and degrade safely', () => {
  assert.equal(harness.noun('month'), 'this month');
  assert.equal(harness.noun('day'), 'today');
  assert.equal(harness.noun('week'), 'this week');
  assert.equal(harness.noun('year'), 'this year');
  assert.equal(harness.noun('ever'), '');
  assert.equal(harness.noun('something-new-from-the-server'), '',
    'an unknown period says nothing rather than guessing');
  assert.equal(harness.heading('Gold'), 'Your Gold perks');
  assert.equal(harness.heading(''), 'Your tier perks');
});

test('v501 only perks the counter would honour are listed, and they are counted in the tab', () => {
  const loader = block('const loadRewards=async()=>', 'const activityState={items:[],nextCursor:null}');
  assert.match(loader, /customerRpc\('customer_get_tier_benefits_v501',\{p_business_slug:businessSlug\}\)/,
    'the customer read is fetched WITH the catalogue, not in a second pass');
  /* nestly_v502: every perk the tier carries is LISTED (greyed when spent — see the v502 tests
     below); only the claimable ones are COUNTED, so the tab can never promise the counter
     something it would refuse. */
  assert.match(loader, /const tierPerksClaimableV502=tierPerksV501\.filter\(perk=>perk\.claimable_now===true\);/,
    'the claimable subset must still be derived, because the tab count depends on it');
  assert.match(loader, /Available\$\{readyCountV397\+entitlementsV429\.length\+tierPerksClaimableV502\.length\?/,
    'a GREYED perk in the Available tally would overstate what the counter will accept');
  assert.match(loader, /\(entitlementsV429\.length\|\|tierPerksV501\.length\)\?''/,
    '"nothing to claim yet" must not be printed above a perk the customer can walk in and use');
  assert.match(loader, /data-customer-tier-perks-v501/);
});

test('v501/UI the tier editor stacks instead of being laid out as a row', () => {
  /* Owner: "i already told you to fix the UI UX - it is still looking very ugly, there's still
     overlapping". MEASURED at 1280px before the fix: the form's own children were flex items on
     one line pushed apart by space-between — "Edit tier" at left 56, "Tier name" at 431,
     "Required points" at 976, each centred at a different height. */
  assert.match(indexHtml, /\.grow-setup-rewardlist-v301>li\.imp-note\{display:block\}/,
    'no note/confirm/form block in this list is a row item');
  assert.match(indexHtml, /\.grow-setup-rewardlist-v301>li\.grow-tier-form-v501\{font-size:inherit;color:inherit;/,
    'and the tier FORM leaves the 12px brown note styling behind');
  assert.match(app, /<li class="imp-note grow-tier-form-v501" data-grow-tiers-addform-v331>/,
    'the form carries the class the rule targets');
  assert.match(indexHtml, /#growTiersBenefitTemplateV363\{flex:0 1 260px;min-width:190px\}/,
    'the benefit-template picker had shrunk to 98px and truncated its label mid-word ("Discou")');
});

/* ==============================================================================================
 * nestly_v502 — a spent perk stays visible, greyed, and says when it comes back
 *
 * Owner, 2026-08-25: "yes keep it visible greyed out until 1 sep". A standing tier right that
 * disappears the moment it is used reads to its holder as a right that was taken away.
 * ============================================================================================ */

const spentPerk = {
  benefit_id: 'b-1', tier_label: 'Gold', sentence: '20% off — 1 per month',
  remaining: 0, limit_period: 'month', period_ends_at: '2026-09-01T00:00:00+08:00',
  claimable_now: false, blocked_reason: 'used_up'
};

test('v502 a spent perk is greyed and kept, never hidden', () => {
  const html = harness.card(spentPerk);
  assert.match(html, /customer-tier-perk-spent-v502/, 'the greyed treatment is on the card itself');
  assert.match(html, /data-tier-perk-claimable-v502="no"/);
  assert.match(html, /20% off — 1 per month/, 'the perk still names itself');
  assert.match(html, /Already used this month\./);
  assert.match(indexHtml, /\.customer-tier-perk-spent-v502\{opacity:\.66;border-style:dashed\}/,
    'greyed must be legible — the "Back on" line is the whole reason the card is still here');
});

test('v502 the spent card prints the RETURN date, and the live card the LAST USABLE day', () => {
  /* Two different ends of one instant. The server says the August window closes at 1 Sep 00:00
     SGT. While the perk is usable that means "use by 31 Aug"; once it is spent it means "back on
     1 Sep". Printing either one in the other's place misinforms by a day. */
  const live = harness.card(goldPerk);
  const spent = harness.card(spentPerk);
  assert.match(live, /Use by 31 Aug 2026/);
  assert.doesNotMatch(live, /Back on/, 'a usable perk must not talk about coming back');
  assert.match(spent, /Back on 1 Sep/, 'the day the allowance renews');
  assert.doesNotMatch(spent, /Use by/, 'a spent perk must not advertise a deadline to use it');
  assert.match(spent, /data-tier-perk-back-v502="2026-09-01T00:00:00\+08:00"/);
});

test('v502 a spent perk offers no counter instruction, because there is nothing to hand over', () => {
  const spent = harness.card(spentPerk);
  assert.doesNotMatch(spent, /member QR/,
    'telling a customer to show a QR for a perk the till would refuse is the v495 contradiction');
  assert.doesNotMatch(spent, /data-tier-perk-remaining-v501/, 'no "0 left" — it says "already used"');
});

test('v502 a birthday perk out of season is NOT given a monthly return date', () => {
  /* It comes back in the customer's birthday month, which this card cannot know — so it says the
     true thing rather than inventing the 1st of next month. */
  const bday = harness.card({
    benefit_id: 'b-3', tier_label: 'Diamond', sentence: 'Free cake',
    remaining: 1, limit_period: 'birthday_month', period_ends_at: '2026-09-01T00:00:00+08:00',
    claimable_now: false, blocked_reason: 'not_birthday_month'
  });
  assert.match(bday, /Yours during your birthday month\./);
  assert.match(bday, /data-tier-perk-state-v502="birthday"/);
  assert.doesNotMatch(bday, /Back on/, 'a birthday perk does not renew on the 1st of next month');
  assert.doesNotMatch(bday, /Use by/);
  assert.match(bday, /customer-tier-perk-spent-v502/, 'still greyed — it cannot be used today');
});

test('v502 every perk is listed, but only claimable ones are counted', () => {
  const loader = block('const loadRewards=async()=>', 'const activityState={items:[],nextCursor:null}');
  assert.match(loader, /\.filter\(perk=>perk&&typeof perk==='object'\)/,
    'the list is no longer narrowed to claimable — that is the whole v502 change');
  /* Precisely: the LIST's own filter must not be the claimable one. (An earlier version of this
     assertion used a loose [\s\S]{0,400} window and matched the tierPerksClaimableV502 line on the
     next line down — a test that failed on correct code. Pin the exact shipped substring instead.) */
  assert.ok(!loader.includes(":[]).filter(perk=>perk&&perk.claimable_now===true)"),
    'the old claimable-only list must be gone, not merely shadowed');
  const listLine = loader.slice(loader.indexOf('const tierPerksV501='));
  assert.ok(listLine.slice(0, listLine.indexOf(';')).includes("typeof perk==='object'"),
    'the list itself keeps every perk the tier carries');
});
