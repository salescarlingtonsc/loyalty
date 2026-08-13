/* V300 growth loop — regressions for the owner-approved 2026-08-13 scope.
 *
 * Each assertion fails against the pre-V300 source:
 *  1. The customer referral card renders ONLY from a server {enabled:true}; every other answer
 *     (programme off, module off, backend missing, denial, transport error) removes the slot.
 *     The card states the firm's LIVE terms and the member's own code, and shares through the
 *     V264 device-sheet-first machinery with the V267 co-brand.
 *  2. The retention page carries the come-back card: away-now from the v244 lapsed reader and
 *     came-back from the v300 returned reader — the same valid-visit predicate on both sides —
 *     with descriptive copy that claims no cause.
 *  3. Business Insights supports calendar grains and an owner-chosen baseline: the verdict band
 *     names an explicit compared period, the derived previous-window phrasing is unchanged, and
 *     the calendar arithmetic is pure string/UTC (no browser timezone).
 *  4. Customer 360 states Last visit from the SAME valid-visit set as its Visits number, and
 *     Rewards claimed only when the reversal projection loaded (unreversed redemptions only).
 *  5. Reward cards on Programmes state real redemption counts; no zero is ever invented.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');
const indexHtml=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');

test('referral card renders only from a server yes and shares co-branded',()=>{
  assert.match(app,/function customerReferralCardMarkupV300\(card,business\)/);
  assert.match(app,/const \{data,error\}=await customerRpc\('customer_get_referral_card_v300',\{p_business_slug:businessSlug\}\)/);
  assert.match(app,/if\(error\|\|data\?\.enabled!==true\)\{slot\.remove\(\);return\}/);
  assert.match(app,/<div id="walletReferralSlot" hidden><\/div>/);
  assert.match(app,/loadReferralCardV300\(\),loadGrowthOffers\(\)/);
  assert.match(app,/shareCustomerReferralV300/);
  assert.match(app,/customer\.referral_shared/);
  assert.match(app,/showCustomerShareSheetV264\(\{text,url,business,onChannel:record,title:ct\('shareYourCode'\)\}\)/);
  assert.match(app,/customerShareSheetMarkupV264\(\{text,url,business=\{\},title='Share this offer'\}\)/);
});

test('referral copy exists in all four customer locales with the firm terms templated',()=>{
  for(const key of ['referralHeading','referralTermsWithFloor','referralTerms','referralShareMessage','referredCount','shareYourCode']){
    const occurrences=(app.split(`${key}:`).length-1);
    assert.ok(occurrences>=4,`expected ${key} in all four locale blocks, saw ${occurrences}`);
  }
  assert.match(app,/referralTermsWithFloor:'They quote your code when they join\. Once they spend \{floor\}, you get \{reward\} in credit\.'/);
});

test('retention page carries the come-back card fed by v244 + v300 on the same visit predicate',()=>{
  assert.match(app,/<section id="comebackHost"/);
  assert.match(app,/renderComebackCardV300\(\{isCurrent:isRetentionCurrent\}\)/);
  assert.match(app,/retention_lapsed_candidates_v244',\{p_business:S\.biz\.id,p_lapsed_days:awayDays,p_min_visits:1\}/);
  assert.match(app,/staff_list_returned_customers_v300',\{p_business:S\.biz\.id,p_away_days:awayDays,p_window_days:30\}/);
  assert.match(app,/Observed visits only — this card claims no cause\./);
  assert.match(app,/Came back in the last 30 days/);
  assert.match(app,/data-comeback-days="\$\{days\}"/);
});

test('insights verdict band names an explicit baseline and keeps derived phrasing',()=>{
  assert.match(app,/const periodWords=periodLabel\|\|`the previous \$\{days\} day\$\{days===1\?'':'s'\}`/);
  assert.match(app,/periodLabel:scope\.priorLabel\|\|''/);
  assert.match(app,/priorLabel=`the compared period \(\$\{compareFrom\} to \$\{compareTo\}\)`/);
  assert.match(app,/function reportCalendarPresetV300\(kind,todayStr\)/);
  assert.match(app,/data-report-preset-cal="\$\{presetKind\}"/);
  assert.match(app,/\[\['month','This month'\],\['lastmonth','Last month'\],\['quarter','This quarter'\],\['lastquarter','Last quarter'\],\['year','This year'\]\]/);
  assert.match(app,/id="reportCompareDetailsV300"/);
  assert.match(app,/id="reportCompareClear"/);
  assert.doesNotMatch(app.split('function reportCalendarPresetV300')[1].split('function reportPriorWindowV297')[0],/new Date\(\)/);
});

test('customer 360 states Last visit and honest Rewards claimed',()=>{
  assert.match(app,/canReadSales&&lastVisitIso\?summaryRowV294\('Last visit'/);
  assert.match(app,/canReadLoyalty&&!reversalActionsUnavailable&&reversalData!==null\?summaryRowV294\('Rewards claimed',`<b>\$\{histRedemptions\.filter\(r=>!r\.reversed_at\)\.length\}<\/b>`\):''/);
});

test('reward cards annotate real redemption counts, never zeros',()=>{
  assert.match(app,/business_reward_redemption_counts_v300',\{p_business:S\.biz\.id\}/);
  assert.match(app,/if\(!\(redeemed>0\)\|\|card\.querySelector\('\.reward-card-redeemed-v300'\)\)return/);
  assert.match(app,/Redeemed \$\{redeemed\} time\$\{redeemed===1\?'':'s'\}/);
  assert.match(indexHtml,/\.reward-card-redeemed-v300\{display:block;font-size:11\.5px;color:var\(--muted\);margin-top:3px\}/);
  assert.match(indexHtml,/\.customer-referral-code\{[^}]*border:1\.5px dashed var\(--coral\)/);
});
