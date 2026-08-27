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
  /* nestly_v465 re-pinned (owner ruling R1). v457's pin said Home prints no quantity at all. The
     owner has reversed that: the quantity comes back, from the server. What must NOT come back is
     the thing v457 actually killed — a number Home worked out for itself. So the rule pinned here
     is now: the greeting's figure is customerRewardReadyTotalV465(cards), which is the sum of the
     server's per-card ready_count and of nothing else, and it is only printed when every card
     supplied one. The old number-free sentence survives as the fallback for a pre-v465 server. */
  assert.match(app,/const readyCardsV457=customerRewardReadyCountV343\(cards\)/);
  assert.match(app,/const rewardReadyV457=readyCardsV457>0/);
  assert.match(app,/const readyTotalV465=customerRewardReadyTotalV465\(cards\)/);
  assert.match(app,/readyTotalV465\.known&&readyTotalV465\.total>0[\s\S]{0,120}customerRewardReadyLineV397\(readyTotalV465\.total\)/);
  assert.match(app,/rewardReadyV457\?`<b>\$\{esc\(readyLineV465\)\}<\/b>`/);
  assert.doesNotMatch(app,/esc\(customerPointTotalV103\(rewardCount\)\)/,
    'the browser still never invents the quantity');
  /* The sum reads ready_count and nothing else — no arithmetic over balances or reward objects. */
  const totalFn=app.slice(app.indexOf('function customerRewardReadyTotalV465'),
    app.indexOf('/* nestly_v428 (item 6) — "2 REWARDS READY"'));
  assert.match(totalFn,/customerCardReadyCountV465\(card\)/);
  assert.doesNotMatch(totalFn,/available_now|remaining_units|balance/,
    'the greeting may not derive readiness from anything but the server count');
  assert.match(app,/function customerProgrammeCardMetricKindV360/);
  assert.match(app,/if\(hasStamps&&!hasPoints\)return 'stamps'/);
  assert.match(app,/if\(tierLabel\)return 'points'/);
  assert.match(app,/customerProgrammeDirectoryMetricV346\(card\)/);
  assert.match(app,/customerHomeBusinessBalanceV345\(card\)/);
  /* nestly_v422 (owner photo 4, "13 / 13 stamps" ringed: "for stamps dont need show this"; photo 5,
     the same figure on the home card: "don't write this"). Both helpers now return '' for a stamps
     firm. The denominator was the reason: it came from ONE reward's cost, not the card's length, so
     it disagreed with the card the customer opened — and the status line beside it ("1 reward
     ready" / "2 stamps to go") already carried the fact. Points are untouched. */
  const metricFn=app.slice(app.indexOf('function customerProgrammeDirectoryMetricV346'),
    app.indexOf('function customerProgrammeDirectoryStatusV346'));
  const homeFn=app.slice(app.indexOf('function customerHomeBusinessBalanceV345'),
    app.indexOf('function customerHomeBusinessCardV345'));
  for(const [name,fn] of [['directory metric',metricFn],['home balance',homeFn]]){
    assert.match(fn,/if\(unit==='stamps'\)return ''/,`${name} prints nothing for stamps`);
    assert.match(fn,/customerPointTotalV103\(balance\)\} pts/,`${name} still prints points`);
    assert.doesNotMatch(fn.replace(/\/\*[\s\S]*?\*\//g,' '),/stamps`/,
      `${name} has no stamps figure left to print`);
  }
  /* An empty figure must not leave an empty slot behind it. */
  assert.match(app,/\$\{metric\?`<div class="customer-programme-card-balance"><b>/,
    'the tile drops the balance box when there is no metric');
  assert.match(app,/\$\{customerHomeBusinessBalanceV345\(card\)\?`<strong>/,
    'and the home card drops its balance line');
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
  /* 2026-08-20 contrast correction: the GROUND is unchanged — still --peekaa-red-soft — but the
     type on it moved from --peekaa-red (#C24135, 3.94:1 on that pink, under AA) to the
     --peekaa-red-on-soft step (#9D352C, 5.43:1). The lock moves with it and keeps the same
     strength: the exact rule, the exact token names, both halves of the pair. */
  assert.match(indexHtml,/\.customer-primary-nav a\[aria-current="page"\],[^{]+\.is-active\{background:var\(--peekaa-red-soft\)!important;border-color:var\(--peekaa-red\)!important;color:var\(--peekaa-red-on-soft\)!important\}/);
  assert.match(indexHtml,/--brand-red-on-soft:var\(--brand-red-dark\);/,
    'the on-soft step must stay derived from the brand ramp, not be a new invented red');
  assert.match(indexHtml,/--peekaa-red-on-soft:var\(--brand-red-on-soft\);/);
  assert.match(indexHtml,/--brand-red-on-soft:var\(--brand-red-on-dark\);/,
    'dark inverts the soft ground, so the colour that sits on it must invert with it');
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
  /* nestly_v422 (owner photo 8: a map pin drawn over the Locations chip, "remove this wording", and
     "company bio has its own line"). Both marks were this track. A worded chip reserved 166–184px
     for the actions column; MEASURED at 390px that left the identity button 130px with an 89px
     text column, so "Cubbly SPA" wrapped and ellipsised and the bio needed 120px in 89px and broke
     mid-phrase. Two icon buttons ask for what they need instead. */
  assert.match(indexHtml,/\.customer-business-header-v346\{grid-template-columns:28px minmax\(0,1fr\) auto!important;gap:8px!important;align-items:center!important;min-height:56px!important\}/);
  assert.match(indexHtml,/\.customer-business-actions-v346\{grid-column:3!important;grid-row:1!important;display:grid!important;grid-template-columns:auto 34px!important;gap:6px!important;align-self:center!important;margin:0!important;min-width:0!important;overflow:hidden!important\}/);
  assert.match(indexHtml,/\.customer-business-actions-v346 \.customer-business-address-icon-v422\{width:34px!important;padding:0!important;justify-content:center!important\}/,
    'the wordless chip is the same 34px square the Call button already is');
  assert.match(indexHtml,/\.customer-business-actions-v346 \.customer-business-address-v366\{justify-content:flex-start!important\}/);
  assert.match(indexHtml,/\.customer-business-actions-v346 \.customer-business-call-icon-v366 span\{display:none!important\}/);
  assert.match(indexHtml,/\.customer-business-profile-v346 \.customer-business-summary-v346\{margin-top:2px!important\}/);
  assert.match(app,/const compactHeaderContactV366=contactHostV326\.classList\.contains\('customer-business-actions-v346'\)/);
  /* nestly_v397 (owner photo C: the chip's address struck through, "Locations" written over it).
     The compact chip used to print a truncated address — "313 Orcha…" — which names nothing, and
     since v386 the full address is printed on its own line directly below it. The chip opens the
     company-details sheet, which lists every branch, so it says what it opens. The wide header
     still prints the address itself, and the full address stays as the chip's title. */
  /* nestly_v422 reversed the v397 half of this: in the COMPACT header the chip carries no label at
     all now. The WIDE header still prints the address itself — it has the room, and there the
     address is the useful label. */
  assert.match(app,/compactHeaderContactV366\?''\s*\n?\s*:\(branch\.address\?String\(branch\.address\):'Locations'\)/,
    'no wording in the compact header; the wide header still prints the address');
  assert.match(app,/rawAddressLabelV366\?`<span>\$\{esc\(rawAddressLabelV366\)\}<\/span>`:''/,
    'and the empty label emits no empty span');
  assert.match(app,/aria-label="\$\{esc\(compactHeaderContactV366\?`Locations — \$\{addressTitleV366\}`:addressTitleV366\)\}"/,
    'a screen reader still gets both the purpose and the address');
  assert.doesNotMatch(app,/shortAddressLabelV366/,'the truncating helper is gone with it');
  assert.match(app,/title="\$\{esc\(addressTitleV366\)\}"/,'the real address survives as the title');
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
  /* nestly_v465 (owner ruling R1): the hero also takes the SERVER's per-business ready count off
     the same actionable card Home reads, so the pill on this page and the line on Home start from
     one number instead of agreeing only after loadRewards. */
  assert.match(collapsed,/customerBusinessRelationshipSummaryV346\(\{loyalty,reward,tier,presentation,packages,membership,bookingEnabled,business,programmeCapabilities,readyCount:customerCardReadyCountV465\(actionableCard\),readyChooseOne:customerCardReadyChooseOneV465\(actionableCard\),stampSlots:stampSlotsV567\}\)/);
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
  /* nestly_v517 (owner: "standardise the font for all the fonts in my customer app ... change
     to something less fanciful — you can see the font dancing"). The customer surface used
     Georgia as its display face in 18 places beside the system stack everywhere else, which
     is the mixture the owner was seeing. One family now. The heading still gets its OWN rule
     — that is what this assertion has always been protecting — it just names var(--sf). */
  assert.match(indexHtml,/\.customer-business-offers-head-v349 h2\{font-family:var\(--sf\)/);
  assert.doesNotMatch(indexHtml,/font-family:Georgia/, 'the customer app carries one font family');
  assert.match(indexHtml,/\.customer-shell \.card\.customer-business-summary-v346\{[^}]*linear-gradient\(145deg,var\(--brand-red\) 0%,var\(--brand-red-dark\) 100%\)/);
  /* nestly_v571 (owner, two photos: "number can be smaller", and 77,877 overflowing the
     Business Profile live preview). The figure is capped below the old fixed 56px and scales with
     its container; what this line protects — that the hero figure is sized deliberately and with
     !important, against the shell's cascade — is unchanged. */
  assert.match(indexHtml,/\.customer-business-balance-v347\{[^}]*font-size:clamp\(30px,8\.5vw,44px\)!important/);
  assert.match(indexHtml,/\.customer-business-summary-actions-v349\{[^}]*grid-template-columns:1fr 1fr!important/);
  assert.match(indexHtml,/\.customer-referral-code-row\{[^}]*grid-template-columns:1fr 1fr!important/);
});
