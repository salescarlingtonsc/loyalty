import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

/* V310 W4b — the customer programme card STACK.
 *
 * Until now a customer's programmes were tabs, and which tab existed came from a MODE
 * (customerProgrammeModeV230), not from the firm's actual programmes. A stamps firm carries
 * points_mode='redeem' after the v306 hotfix, so it fell through the redeem branch and was
 * rendered under a hard-coded heading reading "Reward points", printing "8 stamps" beneath it,
 * with no rings anywhere in the file. Four programmes had nowhere to live at all.
 *
 * The stack is one card per programme the firm runs, in a fixed order, gated on the v310
 * capabilities payload. This suite guards the eight rules that make it safe to ship:
 *   1. the gate falls back to the v194 tabs whenever `programmes` is absent — the four-hour
 *      Cloudflare window AND the rollback path;
 *   2. the order is fixed, whichever programmes are on;
 *   3. a programme the firm never ran renders nothing (no filler cards);
 *   4. a PAUSED programme keeps its card and says so, and pausing one never blanks another —
 *      except Tier (v326 owner ruling): a paused Tier card drops out of the stack entirely;
 *   5. exactly one .customer-programme-balance in the stack (one hero);
 *   6. the Tier card never references loyalty.balance — spendable is not lifetime;
 *   7. the referral card renders only from the server's own {enabled:true};
 *   8. no rings when no reward cost is known — never a made-up N.
 */

const appJs=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');
const indexHtml=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const section=(start,end,source=appJs)=>{
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing section ${start} … ${end}`);
  return source.slice(from,to);
};

/* The stack, its tier/points collaborators and the real copy tables, evaluated exactly as they
   ship. Nothing about the sentences is stubbed: an assertion about what a customer reads has to
   read the same table the customer's browser does. */
const harness=new Function('esc','CUI','walletDate',`
  ${section('const CUSTOMER_COPY=Object.freeze({','const normalizeCustomerLocale=')}
  let customerLocale='en';
  ${section('function ct(key,vars={}){','function customerMediaUrlV95')}
  ${section('function customerPointTotalV103(','const CUSTOMER_SEEN_OFFERS_KEY_V167')}
  ${section('function customerRewardProgressMarkupV167(','function customerTierHasProgressV103')}
  ${section('function customerTierRungIconV195(','function customerProgrammeSummaryTabsV194')}
  ${section('function customerProgrammeSummaryTabsV194','function wireCustomerProgrammeTabsV194')}
  ${section('const programmeStackV310=','function customerMerchantExperienceMarkupV95')}
  return {programmeStackV310,customerProgrammeStackV310,programmeStackCardVisibleV310,
    customerStampTargetV310,customerProgrammeSummaryTabsV194,customerProgrammeTierCardV310,
    PROGRAMME_STACK_ORDER_V310,ct,
    setLocale:value=>{customerLocale=value}};`)(
  value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),
  {icon:()=>''},
  value=>new Date(value).toLocaleString('en-SG',{timeZone:'Asia/Singapore',dateStyle:'medium'}));

const spine=overrides=>['points','tiers','stamps','referral'].map(kind=>({
  kind,active:false,customer_visible:false,running_since:null,paused_since:null,
  balance_scope:'business_pot',...(overrides[kind]||{})}));
const running=since=>({active:true,customer_visible:true,running_since:since||'2026-01-01T00:00:00Z'});
const paused=since=>({active:false,customer_visible:false,running_since:'2026-01-01T00:00:00Z',
  paused_since:since||'2026-07-01T00:00:00Z'});

const TIER={basis:'visits',metric:7,progress_percent:70,
  current:{label:'Explorer',threshold:0,benefits:['A warm hello']},
  next:{label:'Pioneer',threshold:10,benefits:['10% off']},
  tiers:[{label:'Explorer',threshold:0,current:true,benefits:['A warm hello']},
    {label:'Pioneer',threshold:10,benefits:['10% off']}]};
const LOYALTY={enabled:true,balance:180,unit:'points'};
const REWARD={name:'Free flat white',cost_units:300,remaining_units:120,available_now:false};

const render=(programmes,extra={})=>harness.customerProgrammeStackV310({
  programmes,tier:TIER,loyalty:LOYALTY,presentation:{unit:'points',balance:180},
  reward:REWARD,rewardsHost:true,...extra});
const cardOrder=html=>[...html.matchAll(/data-programme-card="([a-z]+)"/g)].map(match=>match[1]);

/* ------------------------------------------------------------------ 1 · the gate is the window */

test('the gate needs BOTH the array and the contract version, and falls back otherwise',()=>{
  const {programmeStackV310}=harness;
  assert.equal(programmeStackV310(undefined),null);
  assert.equal(programmeStackV310({}),null,'a pre-v310 server sends neither key');
  assert.equal(programmeStackV310({programmes:spine({points:running()})}),null,
    'an array with no contract version is not a v310 payload');
  assert.equal(programmeStackV310({programmes:{},programmes_contract:'v310'}),null,
    'presence is never truthiness — the shape is checked too');
  assert.equal(programmeStackV310({programmes:[],programmes_contract:'v311'}),null,
    'a future contract the client has not been taught is not assumed compatible');
  assert.equal(programmeStackV310({programmes:[],programmes_contract:'v310'}),null,
    'an EMPTY programmes array is a server-invariant violation (v308: four rows always) — the '
    +'client keeps a floor under it and falls back to the tabs rather than a blank region');
});

test('with the gate closed the wallet renders the v194 tabs byte-identically to today',()=>{
  /* This is the four-hour Cloudflare window and the rollback path in one assertion: the call site
     is a ternary whose false arm is the untouched v194 call, so a bundle that reaches an older
     server (or a server rolled back under a newer bundle) draws exactly what shipped before. */
  assert.match(appJs,/\$\{programmeStackV310\(programmeCapabilities\)\n\s+\?customerProgrammeStackV310\(/);
  assert.match(appJs,/:customerProgrammeSummaryTabsV194\(\{tier,loyalty,presentation,reward,rewardsHost,capabilities:programmeCapabilities\}\)\}/);
  const tabs=harness.customerProgrammeSummaryTabsV194({tier:TIER,loyalty:LOYALTY,
    presentation:{unit:'points'},reward:REWARD,rewardsHost:true,
    capabilities:{points_mode:null,tiers:true,rewards:true}});
  assert.match(tabs,/data-programme-tab="tier"/);
  assert.match(tabs,/data-programme-tab="points"/);
  assert.doesNotMatch(tabs,/data-programme-card=/,'the fallback path draws tabs, never stack cards');
});

test('every legacy renderer the fallback path needs is still declared',()=>{
  /* Deleting a declaration while leaving a reference passes node --check and the whole suite, then
     crashes in production. The fallback path is the rollback path, so its five functions are load
     bearing even though nothing on a v310 server calls them. */
  for(const name of ['customerProgrammeModeV230','customerProgrammePointsPanelV230',
    'customerProgrammeTierPanelV230','customerProgrammeSummaryTabsV194','wireCustomerProgrammeTabsV194'])
    assert.ok(appJs.includes(`function ${name}(`),`${name} must stay declared for the fallback path`);
  assert.ok(appJs.indexOf('const programmeStackV310=')>appJs.indexOf('function wireCustomerProgrammeTabsV194('),
    'the stack goes AFTER the tab wiring so no existing section boundary moves');
});

/* --------------------------------------------------------------------- 2 · the order is fixed */

test('the order is stamps → points → tier → referral however the firm turned them on',()=>{
  assert.deepEqual([...harness.PROGRAMME_STACK_ORDER_V310],['stamps','points','tiers','referral']);
  const all=render(spine({stamps:running(),points:running(),tiers:running(),referral:running()}));
  assert.deepEqual(cardOrder(all),['stamps','points','tiers']);
  assert.ok(all.indexOf('walletReferralSlot')>all.indexOf('data-programme-card="tiers"'),
    'referral is position 4, after the tier card');
  /* The payload is spine `sort` order, but the stack must not inherit it: a server that reorders
     its rows must not reorder the customer's cards. */
  const shuffled=render([...spine({stamps:running(),points:running(),tiers:running()})].reverse());
  assert.deepEqual(cardOrder(shuffled),['stamps','points','tiers']);
});

/* ------------------------------------------------------ 3 · no filler cards, ever */

test('a programme the firm never ran renders nothing at all',()=>{
  const onlyPoints=render(spine({points:running()}));
  assert.deepEqual(cardOrder(onlyPoints),['points'],'one live programme, one card');
  assert.doesNotMatch(onlyPoints,/customer-referral-card-v300/,
    'the referral SLOT is emitted unconditionally, as it always was, but nothing fills it here');
  assert.equal(harness.programmeStackCardVisibleV310(null),false);
  assert.equal(harness.programmeStackCardVisibleV310(
    {kind:'stamps',active:false,paused_since:null,running_since:null}),false,
    'active:false with no paused_since is a programme this firm never ran');
  assert.equal(harness.programmeStackCardVisibleV310({kind:'stamps',active:true}),false,
    'active alone is programme truth, not presentation — the server binds customer_visible to '
    +'the same legacy capabilities the v194 tabs read, and the client OBEYS it so the two '
    +'bundles cannot diverge inside the CDN window (a points programme with no reward yet is '
    +'active but not customer-visible)');
  assert.equal(harness.programmeStackCardVisibleV310(
    {kind:'stamps',active:true,customer_visible:true}),true);
  assert.equal(harness.programmeStackCardVisibleV310(
    {kind:'stamps',active:false,paused_since:'2026-07-01T00:00:00Z'}),true);
});

/* --------------------------------------------------------- 4 · a paused programme keeps its card */

test('a paused programme keeps its card, says so, and never blanks the others',()=>{
  const html=render(spine({points:paused('2026-07-01T00:00:00Z'),tiers:running(),stamps:running()}));
  assert.deepEqual(cardOrder(html),['stamps','points','tiers'],
    'pausing points removes neither the stamps card nor the tier card');
  const points=section('data-programme-card="points"','data-programme-card="tiers"',html);
  assert.match(points,/Programme paused/);
  assert.match(points,/Anything you already earned is kept/);
  assert.match(points,/1 Jul 2026/,'the card says since when, from the server’s own breadcrumb');
  assert.doesNotMatch(points,/customer-programme-balance/,
    'a paused programme discloses no balance — the server zeroes it, and a bare 0 is a lie');
  const tiers=html.slice(html.indexOf('data-programme-card="tiers"'));
  assert.match(tiers,/Explorer/,'the tier card is untouched by the points pause');
});

/* v326 (owner: "if programme is paused/not live, remove from customer app" — annotated on the
   Tier card specifically): unlike every other card in the stack, a paused TIER card no longer
   renders at all, rather than showing "Programme paused". This is the one deliberate exception
   to rule 4 above; stamps/points/referral paused behaviour is untouched. */
test('each card reads its OWN active flag, not a single programme-wide one — Tier is the paused exception',()=>{
  const tierPaused=render(spine({points:running(),tiers:paused()}));
  assert.deepEqual(cardOrder(tierPaused),['points'],
    'a paused Tier programme drops its card entirely; points is running, so its own card is the only one left');
  assert.match(tierPaused,/customer-programme-balance/,'points is running, so its figure stands');
  assert.doesNotMatch(tierPaused,/data-programme-card="tiers"/,'no tier card at all while its programme is paused');
  assert.doesNotMatch(tierPaused,/Explorer/,'a paused tier programme does not show a rung it is not awarding');
});

/* -------------------------------------------------------------------- 5 · exactly one hero */

test('exactly one .customer-programme-balance in a four-programme stack',()=>{
  const html=render(spine({stamps:running(),points:running(),tiers:running(),referral:running()}));
  assert.equal((html.match(/class="customer-programme-balance"/g)||[]).length,1,
    'one number, one owner: the Points card');
  const points=section('data-programme-card="points"','data-programme-card="tiers"',html);
  assert.match(points,/class="customer-programme-balance"/);
  const stamps=section('data-programme-card="stamps"','data-programme-card="points"',html);
  assert.doesNotMatch(stamps,/class="customer-programme-balance"/,
    'the stamps figure is the ring row, not a second hero number');
});

test('no stack shape ever prints the hero twice',()=>{
  for(const overrides of [{points:running()},{stamps:running()},{tiers:running()},
    {stamps:running(),points:paused()},{points:running(),tiers:running()},
    {stamps:running(),points:running(),tiers:running(),referral:running()}]){
    const html=render(spine(overrides));
    assert.ok((html.match(/class="customer-programme-balance"/g)||[]).length<=1,
      `more than one hero for ${JSON.stringify(Object.keys(overrides))}`);
  }
});

/* ------------------------------------------------- 6 · the tier card never speaks in balance */

test('the tier card carries no loyalty.balance reference, in source or in output',()=>{
  /* V256's refutation: the tier metric is sum(points) where entry_type='earn' and redemptions are
     never subtracted, so a customer who earns 5,000 and spends 4,900 keeps the tier the 5,000
     bought and holds 100. The old panel printed that 100 beside the words "points earned". */
  const source=section('function customerProgrammeTierCardV310(','/* The claimable-now strip');
  assert.doesNotMatch(source,/loyalty/,'the tier card is not even given the balance');
  assert.doesNotMatch(source,/customer-programme-balance/);
  const html=harness.customerProgrammeTierCardV310({tier:{...TIER,basis:'points_earned',metric:5000},
    entry:{kind:'tiers',active:true},pointsCardPresent:true});
  assert.doesNotMatch(html,/customer-programme-balance/);
  assert.doesNotMatch(html,/180/,'the spendable balance never reaches this card');
  assert.match(html,/spending them never lowers your tier/,
    'V258’s reassurance, shown because the Points card is present');
});

test('the stack shows the tier card for a redeem-mode firm and keeps the ladder verbatim',()=>{
  /* The v194 panel returns '' for points_mode==='redeem'. Inside the stack presence is decided by
     programmes['tiers'], not by a mode, so that early return must not fire — while the fallback
     path keeps it. */
  const html=harness.customerProgrammeTierCardV310({tier:{...TIER,points_mode:'redeem'},
    entry:{kind:'tiers',active:true},pointsCardPresent:false});
  assert.match(html,/Explorer/,'the redeem-mode early return is dropped inside the stack');
  assert.match(html,/customer-tier-ladder/,'the v186 ladder disclosure is reused as it is');
  assert.doesNotMatch(html,/spending them never lowers your tier/,
    'no Points card, so no answer to a question the customer cannot have');
  assert.match(appJs,/if\(String\(tier\.points_mode\|\|''\)==='redeem'\)\{\n\s+return '';/,
    'the fallback path keeps the early return');
});

/* ------------------------------------------------------------ 7 · referral has one truth only */

test('the stack gives referral a slot, and only the server fills it',()=>{
  const html=render(spine({points:running(),referral:running()}));
  assert.match(html,/<div id="walletReferralSlot" hidden><\/div>/);
  assert.doesNotMatch(html,/customer-referral-card-v300/,
    'the card is never rendered from the spine — that would be a second truth');
  assert.match(appJs,/if\(error\|\|data\?\.enabled!==true\)\{slot\.remove\(\);return\}/,
    'any answer other than {enabled:true} removes the slot, unchanged from V300');
  assert.match(appJs,/slot\.outerHTML=customerReferralCardMarkupV300\(data,/);
});

test('the fallback path keeps the referral slot where it has always been',()=>{
  const merchant=section('function customerMerchantExperienceMarkupV95','function actionableWalletCardMarkup');
  assert.match(merchant,/customerProgrammeOffersMarkupV167[\s\S]{0,220}walletReferralSlot/,
    'below the offers block, exactly as before, when the stack is not rendering');
});

/* --------------------------------------------------------- 8 · never a made-up ring count */

test('no rings when no reward cost is known, and never a default of ten',()=>{
  assert.equal(harness.customerStampTargetV310(null),0);
  assert.equal(harness.customerStampTargetV310({}),0);
  assert.equal(harness.customerStampTargetV310({cost_units:0}),0);
  assert.equal(harness.customerStampTargetV310({cost_units:8}),8);
  const html=render(spine({stamps:running()}),{reward:null});
  const stamps=html.slice(html.indexOf('data-programme-card="stamps"'));
  assert.doesNotMatch(stamps,/customer-programme-stamp-rings/,
    'an unknown N is stated as an unknown N — the plain count and nothing drawn');
  assert.match(stamps,/customer-programme-stamp-count/);
  assert.match(stamps,/180 stamps collected/);
});

test('a known reward cost draws that many rings, filled to the balance',()=>{
  const html=render(spine({stamps:running()}),
    {loyalty:{enabled:true,balance:6,unit:'stamps'},presentation:{unit:'stamps',balance:6},
      reward:{name:'Free pastry',cost_units:10,remaining_units:4,available_now:false}});
  const stamps=html.slice(html.indexOf('data-programme-card="stamps"'));
  assert.equal((stamps.match(/class="customer-programme-stamp-ring[ "]/g)||[]).length,10);
  assert.equal((stamps.match(/customer-programme-stamp-ring is-filled/g)||[]).length,6);
  assert.match(stamps,/aria-label="6 of 10 stamps collected"/,
    'one label carries the whole fact; the rings are decorative to a screen reader');
  assert.match(stamps,/4 more stamps and your next Free pastry is on us\./);
});

test('the stamps card never says "Reward points"',()=>{
  /* What it says today: customerProgrammeModeV230 returns 'redeem' for a stamps firm (v306 leaves
     points_mode='redeem' there), and the redeem branch heads the card, hard-coded, "Reward
     points" — over a figure reading "8 stamps". */
  const html=render(spine({stamps:running(),points:paused()}),
    {loyalty:{enabled:true,balance:8,unit:'stamps'},presentation:{unit:'stamps',balance:8},
      reward:{name:'Free pastry',cost_units:10,remaining_units:2,available_now:false}});
  const stamps=section('data-programme-card="stamps"','data-programme-card="points"',html);
  assert.doesNotMatch(stamps,/Reward points/);
  assert.match(stamps,/Stamp card/);
});

test('the gifts host lands on the accruing card, never on both',()=>{
  const stampsFirm=render(spine({stamps:running(),points:paused()}));
  assert.equal((stampsFirm.match(/id="walletRewards"/g)||[]).length,1);
  const stamps=section('data-programme-card="stamps"','data-programme-card="points"',stampsFirm);
  assert.match(stamps,/id="walletRewards"/,'at a stamps firm the gifts sheet hangs off the stamps card');
  const pointsFirm=render(spine({points:running(),tiers:running()}));
  assert.equal((pointsFirm.match(/id="walletRewards"/g)||[]).length,1);
});

/* ------------------------------------------------------------------ the strip and the W4c slot */

test('the claimable strip is absent unless something really is claimable',()=>{
  const nothing=render(spine({points:running()}));
  assert.doesNotMatch(nothing,/customer-claimable-strip/,'no empty state — an unearned promise');
  const ready=render(spine({points:running()}),
    {reward:{name:'Free flat white',cost_units:300,remaining_units:0,available_now:true}});
  assert.match(ready,/customer-claimable-strip/);
  assert.match(ready,/1 ready to claim/);
  assert.match(ready,/Free flat white/);
});

test('W4c ships as an empty hidden slot, with no member QR',()=>{
  const html=render(spine({points:running()}));
  assert.match(html,/<div id="customerMemberCodeSlotV310" class="customer-member-code-slot" hidden><\/div>/);
  assert.doesNotMatch(html,/nestly:member:/,'the scanner has no member branch yet — W4c owns that');
  assert.match(indexHtml,/\.customer-member-code-slot\{/,'the CSS ships now so W4c is wiring only');
});

/* ---------------------------------------------------------------------------- the stylesheet */

test('the stack styles ship and the tab styles the fallback needs are kept',()=>{
  for(const rule of [/\.customer-programme-stack\{/,/\.customer-programme-card-v310\{/,
    /\.customer-programme-stamp-rings\{/,/\.customer-programme-stamp-ring\{/,
    /\.customer-claimable-strip\{/])assert.match(indexHtml,rule);
  assert.match(indexHtml,/\.customer-programme-stamp-ring\.is-filled\{[^}]*border-style:solid/,
    'filled rings carry a non-colour signal, so the row reads in greyscale');
  assert.match(indexHtml,/@media \(prefers-reduced-motion:reduce\)\{\.customer-programme-stamp-ring\{transition:none\}\}/);
  assert.match(indexHtml,/\.customer-programme-tablist\{/,'the fallback path still needs the tab rules');
  assert.match(indexHtml,/\.customer-programme-tab-balance\{/);
});

/* ------------------------------------------------------------------------------------- i18n */

test('every stack sentence resolves in all four mandate languages',()=>{
  const keys=['stampsCardTitle','pointsCardTitle','tierCardTitle','stampsRemaining','stampsReady',
    'stampsNoGift','pointsRemaining','pointsReady','tierDistance','tierTop','programmePaused',
    'programmePausedBody','claimableNow','claimableCount','showMyCode','showMyCodeBody'];
  for(const locale of ['en','zh-CN','ms','ta']){
    harness.setLocale(locale);
    for(const key of keys)assert.notEqual(harness.ct(key),key,`${locale} does not resolve ${key}`);
  }
  harness.setLocale('ta');
  const html=render(spine({stamps:running(),points:running(),tiers:running()}));
  assert.doesNotMatch(html,/Stamp card|Points &amp; gifts|Programme paused/,
    'a Tamil wallet reads Tamil card titles, not English ones');
  harness.setLocale('en');
});
