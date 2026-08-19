/* V299 customer-experience polish — presentation-only regressions.
 *
 * Each assertion fails against the pre-V299 source:
 *  1. Offer artwork fallbacks show the BUSINESS monogram as a small coin, never a giant
 *     first letter of the offer name ("2-for-1 lattes" rendered a huge lone "2").
 *  2. In tiers+points ("both") mode the spendable balance reads on the tab bar itself —
 *     it no longer hides entirely behind the unselected "Reward points" tab — and it is
 *     suppressed while the programme is paused so it cannot contradict "Programme paused".
 *  3. Customer-surface footers pass the member's locale to legalLinks() instead of
 *     hardcoding English for zh-CN / ms members.
 *  4. Wallet section headings that bypassed the walletSectionShell ct() chokepoint are
 *     translated: Packages, Membership, Recent activity, Full history, Rate your visit,
 *     and the Transactions & points empty state — with dictionary rows in all four locales.
 *  5. The reward card (the claim surface) uses the sibling-card corner radius, not the
 *     legacy 7px from an earlier design pass.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');
const indexHtml=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');

test('offer artwork fallbacks carry the business monogram, not the offer-name initial',()=>{
  /* Wave 4 moved the countdown chip inside the media block, so the block now holds real text and
     its aria-hidden moved down onto the monogram span — the monogram is still the decoration, the
     countdown is not. The monogram itself is unchanged: the BUSINESS initial, never the offer's. */
  assert.match(app,/customer-home-offer-media--fallback"><span aria-hidden="true">\$\{esc\(businessInitial\)\}<\/span>/);
  assert.doesNotMatch(app,/const initial=\(String\(item\?\.name\|\|'Offer'\)\.trim\(\)\[0\]\|\|'O'\)\.toUpperCase\(\)/);
  assert.match(app,/const initial=\(String\(business\?\.name\|\|item\?\.name\|\|'P'\)\.trim\(\)\[0\]\|\|'P'\)\.toUpperCase\(\)/);
  assert.match(app,/initial=\(String\(business\.name\|\|item\?\.name\|\|'P'\)\.trim\(\)\[0\]\|\|'P'\)\.toUpperCase\(\)/);
});

test('fallback CSS renders a small coin while keeping the pinned gradients and aspect ratios',()=>{
  assert.match(indexHtml,/\.customer-home-offer-media--fallback\{[^}]*linear-gradient\(135deg,var\(--tint\),var\(--card\)\)/s);
  /* W5: the rule is scoped to the DIRECT monogram span. Unscoped, it also matched the
   countdown chip's inner text span and squashed it to 46x46, clipping the label. */
  assert.match(indexHtml,/\.customer-home-offer-media--fallback>span\{[^}]*width:46px/s);
  assert.doesNotMatch(indexHtml,/\.customer-home-offer-media--fallback span\{/);
  assert.match(indexHtml,/\.customer-promotion-card-media--fallback\{[^}]*aspect-ratio:21\/9/s);
  assert.match(indexHtml,/\.customer-promotion-card-media--fallback span\{[^}]*width:52px/s);
  assert.match(indexHtml,/\.customer-offer-detail-media--fallback\{[^}]*aspect-ratio:16\/9/s);
  assert.match(indexHtml,/\.customer-offer-detail-media--fallback span\{[^}]*width:56px/s);
  assert.doesNotMatch(indexHtml,/\.customer-home-offer-media--fallback>span\{font-size:2rem/);
});

test('both-mode tab bar carries the spendable balance, suppressed while paused',()=>{
  assert.match(app,/const tabBalanceV299=loyalty\.enabled===false\?''/);
  assert.match(app,/customer-programme-tablist\$\{tabBalanceV299\?' customer-programme-tablist--with-balance':''\}/);
  assert.match(app,/class="customer-programme-tab-balance"/);
  assert.match(indexHtml,/\.customer-programme-tablist--with-balance\{grid-template-columns:minmax\(0,1fr\) minmax\(0,1fr\) auto\}/);
  assert.match(indexHtml,/\.customer-programme-tab-balance\{[^}]*font-variant-numeric:tabular-nums/s);
});

test('customer-surface footers localize the legal links',()=>{
  const localizedCustomerFooters=(app.match(/legalLinks\(customerLocale\)/g)||[]).length;
  assert.ok(localizedCustomerFooters>=7,`expected >=7 customer legalLinks(customerLocale) call sites, saw ${localizedCustomerFooters}`);
  assert.match(app,/<main id="main" tabindex="-1"><div id="walletBody">\$\{body\}<\/div><\/main>\n\s*\$\{legalLinks\(customerLocale\)\}/);
});

test('wallet section headings written outside the shell go through ct()',()=>{
  assert.match(app,/<h2>\$\{esc\(ct\('Packages'\)\)\}<\/h2><p class="muted small">\$\{esc\(ct\('Session balances and recent usage\.'\)\)\}<\/p>/);
  assert.match(app,/<h2>\$\{esc\(ct\('Membership'\)\)\}<\/h2><p class="muted small">\$\{esc\(ct\('Current plan and period status\.'\)\)\}<\/p>/);
  assert.match(app,/<h2>\$\{esc\(ct\('Recent activity'\)\)\}<\/h2>/);
  assert.match(app,/<h2>\$\{esc\(ct\('Rate your visit'\)\)\}<\/h2>/);
  assert.match(app,/<span>\$\{esc\(ct\('Full history'\)\)\}<\/span>/);
  assert.match(app,/<h2>\$\{esc\(ct\('Transactions & points'\)\)\}<\/h2>/);
});

test('the six new copy keys exist in every customer locale',()=>{
  for(const value of ['Recent activity','最近动态','Aktiviti terkini','சமீபத்திய செயல்பாடு']){
    assert.ok(app.includes(`'Recent activity':'${value}'`),`Recent activity → ${value}`);
  }
  for(const key of ['Full history','Rate your visit','Your latest events with this business.',
    'Your review helps other people find this business.',
    'No purchases or points activity has been recorded for this programme yet.']){
    const occurrences=(app.split(`'${key}':`).length-1);
    assert.ok(occurrences>=4,`expected "${key}" in all four locale dictionaries, saw ${occurrences}`);
  }
});

test('the reward card sheds the legacy 7px corner radius',()=>{
  assert.match(indexHtml,/\.wallet-reward\{border:1px solid var\(--hair\);border-radius:14px/);
  assert.doesNotMatch(indexHtml,/\.wallet-reward\{[^}]*border-radius:7px/);
});

test('home and rewards cards keep points/stamps labels honest and compact',()=>{
  assert.match(app,/const rewardWord=rewardCount===1\?'reward':'rewards'/);
  assert.match(app,/\$\{esc\(customerPointTotalV103\(rewardCount\)\)\}<\/span> \$\{esc\(rewardWord\)\} ready/);
  assert.match(app,/function customerProgrammeCardMetricKindV360/);
  assert.match(app,/if\(hasStamps&&!hasPoints\)return 'stamps'/);
  assert.match(app,/if\(tierLabel\)return 'points'/);
  assert.match(app,/customerProgrammeDirectoryMetricV346\(card\)/);
  assert.match(app,/customerHomeBusinessBalanceV345\(card\)/);
  assert.match(app,/\$\{customerPointTotalV103\(balance\)\} \/\ \$\{customerPointTotalV103\(target\)\} stamps/);
  assert.match(app,/\$\{customerPointTotalV103\(balance\)\} pts/);
  assert.doesNotMatch(app,/customerPointTotalV103\(balance\)\} of \$\{customerPointTotalV103\(target\)\} stamps/);
  assert.match(indexHtml,/\.customer-programme-card-balance b\{[^}]*white-space:nowrap!important/s);
  assert.match(indexHtml,/\.customer-home-business-track-v343 \.customer-programme-card-balance b\{[^}]*font-size:10\.5px!important/s);
});

test('customer surface uses the warm premium accent palette without changing the app background',()=>{
  /* Owner ruling 2026-08-18: Peekaa has ONE brand red, #C24135. The customer app previously ran
     on #F06A4F while the business app ran on #C24135. The --peekaa-* names survive as aliases so
     no rule needed rewriting; this now locks the single source and the aliasing that feeds it. */
  assert.match(indexHtml,/--brand-red:#C24135;/);
  assert.match(indexHtml,/--peekaa-red:var\(--brand-red\);--peekaa-red-dark:var\(--brand-red-dark\);--peekaa-red-soft:var\(--brand-red-soft\);--peekaa-red-faint:var\(--brand-red-faint\);/);
  /* Wave 1 (owner-approved 2026-08-19): the --peekaa-* neutrals became aliases of the ONE
     semantic system. The guarantees below are unchanged in strength — the background value and
     the semantic colours are still locked to exact hexes, now at their single source — and the
     aliasing that feeds the customer surface is locked with them. */
  assert.match(indexHtml,/--bg-cust:#F8F4F1;/,
    'the existing customer app background must stay exactly unchanged');
  assert.match(indexHtml,/--peekaa-bg:var\(--bg-cust\);/,
    'the customer background must be fed by the canonical token, not a second literal');
  assert.match(indexHtml,/--peekaa-text:var\(--ink\);--peekaa-text-secondary:var\(--muted\);/);
  assert.match(indexHtml,/--success:#1F6B48; --success-bg:#E7F6EE;/);
  assert.match(indexHtml,/--peekaa-success:var\(--success\);--peekaa-success-bg:var\(--success-bg\);/);
  assert.match(indexHtml,/--gold:#D8B15A;/);
  assert.match(indexHtml,/--peekaa-gold:var\(--gold\);--peekaa-gold-bg:var\(--gold-bg\);/);
  assert.match(indexHtml,/\/\* V361: warm premium customer accents\. The page background stays on --peekaa-bg exactly as-is\. \*\//);
  assert.match(indexHtml,/--glow-brand:0 8px 22px rgba\(194,65,53,\.28\);/,
    'the brand glow keeps its exact recipe, now at its single source');
  assert.match(indexHtml,/\.customer-nav-scan-fab\{background:var\(--peekaa-red\)!important;box-shadow:var\(--glow-brand\)!important\}/);
  assert.match(indexHtml,/\.customer-primary-nav a\[aria-current="page"\],[^{]+\.is-active\{background:var\(--peekaa-red-soft\)!important;border-color:var\(--peekaa-red\)!important;color:var\(--peekaa-red\)!important\}/);
  assert.match(indexHtml,/\.customer-claimable-banner-v337,\.customer-claimable-strip\{border-color:var\(--peekaa-gold\)!important;background:var\(--peekaa-gold-bg\)!important/);
  assert.match(indexHtml,/\.customer-surface \.pill\.ok\{background:var\(--peekaa-success-bg\)!important;color:var\(--peekaa-success\)!important\}/);
});

test('compact customer pills and programme card metrics are optically centered',()=>{
  assert.match(indexHtml,/\/\* V364: optical alignment fixes for compact customer cards and pills\. \*\//);
  assert.match(indexHtml,/\.customer-home-offer-countdown,\.customer-offer-new\{display:inline-flex!important;align-items:center!important;justify-content:center!important;line-height:1!important;white-space:nowrap!important\}/);
  assert.match(indexHtml,/\.customer-home-offer-countdown\{min-height:26px!important;padding:0 12px!important\}/);
  assert.match(indexHtml,/\.customer-programme-card-v95 \.customer-programme-card-balance\{display:flex!important;align-items:center!important;justify-content:flex-end!important;gap:8px!important;align-self:center!important;min-width:0!important;text-align:right!important\}/);
  assert.match(indexHtml,/\.customer-programme-card-v95 \.customer-programme-card-balance span\{display:inline-flex!important;align-items:center!important;justify-content:center!important;line-height:1!important;transform:none!important\}/);
});

test('business detail address and call actions share the merchant header row',()=>{
  assert.match(indexHtml,/\/\* V365: business quick actions sit beside the merchant name to remove the extra row\. \*\//);
  assert.match(indexHtml,/\.customer-business-header-v346\{grid-template-columns:28px minmax\(0,1fr\) minmax\(166px,184px\)!important;gap:8px!important;align-items:center!important;min-height:56px!important\}/);
  assert.match(indexHtml,/\.customer-business-actions-v346\{grid-column:3!important;grid-row:1!important;display:grid!important;grid-template-columns:minmax\(0,1fr\) 34px!important;gap:6px!important;align-self:center!important;margin:0!important;min-width:0!important;overflow:hidden!important\}/);
  assert.match(indexHtml,/\.customer-business-actions-v346 \.customer-business-address-v366\{justify-content:flex-start!important\}/);
  assert.match(indexHtml,/\.customer-business-actions-v346 \.customer-business-call-icon-v366 span\{display:none!important\}/);
  assert.match(indexHtml,/\.customer-business-profile-v346 \.customer-business-summary-v346\{margin-top:2px!important\}/);
  assert.match(app,/const compactHeaderContactV366=contactHostV326\.classList\.contains\('customer-business-actions-v346'\)/);
  assert.match(app,/const shortAddressLabelV366=\(address\)=>/);
  assert.match(app,/compactHeaderContactV366\?'':`<span>Call<\/span>`/);
});

test('business profile shortcuts are relationship-specific, not static decoration',()=>{
  const helperStart=app.indexOf('function customerBusinessDashboardModulesV347');
  const helper=app.slice(helperStart,app.indexOf('/* v340',helperStart));
  assert.match(helper,/const hasPoints=visibleEntry\('points'\)/);
  assert.match(helper,/const hasStamps=visibleEntry\('stamps'\)/);
  assert.match(helper,/const hasTiers=visibleEntry\('tiers'\)/);
  assert.match(helper,/if\(hasTiers\)modules\.push\(\{href:'#customerBusinessOverviewDetailV347',action:'tiers'/);
  assert.match(helper,/if\(sessions>0\)modules\.push\(\{href:'#customerBusinessPackagesDetailV347',action:'packages'/);
  assert.match(helper,/if\(hasActivity\)modules\.push\(\{href:'#customerBusinessActivityDetailV347',action:'activity'/);
  assert.match(helper,/if\(membership\.active===true\)modules\.push/);
  assert.match(helper,/if\(hasReferral\)modules\.push\(\{href:'#customerBusinessReferralDetailV362',action:'referral'/);
  assert.match(helper,/data-business-shortcut-v347="\$\{esc\(item\.action\)\}"/);
  assert.match(helper,/function wireCustomerBusinessShortcutsV347/);
  assert.match(helper,/referral:'#customerBusinessReferralDetailV362'/);
  assert.doesNotMatch(helper,/shareButton\.click\(\)/);
  assert.match(helper,/openCustomerBusinessShortcutPageV348\(\{action,title:labels\[action\]/);
  assert.match(helper,/function openCustomerBusinessShortcutPageV348/);
  assert.match(helper,/function closeCustomerBusinessShortcutPageV348/);
  assert.match(helper,/function wireCustomerBusinessShortcutPageV348/);
  assert.match(app,/wireCustomerBusinessShortcutsV347\(\$\(\'walletBody\'\)\)/);
  assert.match(app,/wireCustomerBusinessShortcutPageV348\(\$\(\'walletBody\'\)\)/);
  assert.match(helper,/if\(!modules\.length\)return ''/);
  assert.doesNotMatch(helper,/No active package/);
  const merchant=app.slice(app.indexOf('function customerMerchantExperienceMarkupV95'),app.indexOf('/* W4c lives HERE',app.indexOf('function customerMerchantExperienceMarkupV95')));
  const collapsed=merchant.slice(merchant.indexOf('if(collapsedHeaderV339)return'),merchant.indexOf('return `${customerProgrammeSwitcherMarkup',merchant.indexOf('if(collapsedHeaderV339)return')));
  assert.doesNotMatch(collapsed,/customer-business-book-v346/);
  /* v386 (owner photo 7): the hero takes programmeCapabilities so its shape can follow the
     business's own choice of programme — number, stamp rings, or tier meter. */
  assert.match(collapsed,/customerBusinessRelationshipSummaryV346\(\{loyalty,reward,tier,presentation,packages,membership,bookingEnabled,business,programmeCapabilities\}\)/);
  assert.match(collapsed,/customerRewardOfferSwipeMarkupV339\(\{reward,items:offers,status:offersStatus,business,bookingEnabled,includeReward:false,title:'Limited offers'\}\)/);
  assert.match(collapsed,/customerBusinessReferralDetailMarkupV362\(\)/);
  /* v386 (owner photo 4, the whole card struck through): "Earn more points → Visit and spend
     here" is removed outright, function and both call sites. */
  assert.doesNotMatch(app,/customerEarnMorePointsMarkupV339/);
  assert.match(app,/function customerBusinessReferralDetailMarkupV362/);
  assert.doesNotMatch(app,/id="customerEarnMoreReferralV339"/);
  assert.match(app,/class="customer-business-book-inline-v349"/);
  const wallet=app.slice(app.indexOf('async function renderCustomerWallet'),app.indexOf('async function renderCustomerInAppInbox'));
  assert.match(wallet,/const showPackageGroupV347=showGiftCardSectionV347\|\|capabilities\.packages===true\|\|capabilities\.membership===true/);
  assert.match(wallet,/id="customerBusinessMainV348"/);
  assert.match(wallet,/id="customerBusinessShortcutPageV348" hidden/);
  assert.match(wallet,/id="walletSections" hidden/);
  assert.match(wallet,/\$\{showPackageGroupV347\?`[\s\S]*id="customerBusinessPackagesDetailV347"/);
  assert.match(indexHtml,/\.customer-business-profile-v346>\.customer-business-rewards-v346\{display:none!important\}/);
  assert.match(indexHtml,/\.customer-business-profile-v346>\.customer-business-referral-v362\{display:none!important\}/);
  assert.match(indexHtml,/\.customer-business-shortcut-content-v348>\.customer-business-referral-v362\{display:grid!important\}/);
  assert.match(indexHtml,/\.customer-business-detail-store-v348\[hidden\]\{display:none!important\}/);
  assert.doesNotMatch(indexHtml,/\.customer-business-profile-v346 \.customer-reward-offer-swipe-v339\{display:none!important\}/);
  assert.match(indexHtml,/\.customer-business-offers-head-v349 h2\{font-family:Georgia/);
  assert.match(indexHtml,/\.customer-shell \.card\.customer-business-summary-v346\{[^}]*linear-gradient\(145deg,var\(--brand-red\) 0%,var\(--brand-red-dark\) 100%\)/);
  assert.match(indexHtml,/\.customer-business-balance-v347\{[^}]*font-size:56px!important/);
  assert.match(indexHtml,/\.customer-business-summary-actions-v349\{[^}]*grid-template-columns:1fr 1fr!important/);
  assert.match(indexHtml,/\.customer-referral-code-row\{[^}]*grid-template-columns:1fr 1fr!important/);
});
