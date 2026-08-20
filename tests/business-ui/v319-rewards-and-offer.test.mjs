import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

/* V319 — the owner's three markups of 2026-08-14, on build 5bca979f0990.
 *
 *  1. Customer profile (Mumu): "300" written against the Points System row with "expires in xxx"
 *     beside it, and on the summary card opposite the Points row, its expiry line and Spendable
 *     credit all struck through. The two promotion rows ringed: "these are Ads Promotion, put in
 *     different box".
 *  2. Programmes: "PROGRAMMES" struck out, "Rewards & Offer" written above; "List" struck out,
 *     "Rewards Programme" written; a new "Limited Offer" child added. Over the Overview table, a
 *     two-column frame headed "Rewards & Loyalty" and "Limited Offer": "these two are different
 *     categories"; and of the promotions, "editable in this tab".
 *  3. Dashboard: the period strip ringed in the titlebar with an arrow drawn down to Performance:
 *     "filter time move here".
 *
 * These assertions run the SHIPPED source and read what it emits, rather than grepping app.js for
 * the lines they were written against. That distinction is not academic here: W6 increment 2
 * shipped four inert toggles and a silently re-based tier ladder past nineteen green source pins.
 */

const appJs=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
/* The status vocabulary is a top-level constant in app.js. Slice the REAL definitions in
   rather than restating the words here, so this harness can never drift from the app. */
const STATUS_PRELUDE_SRC=appJs.match(/const STATUS_WORDS=[\s\S]*?const statusOnOff=[^\n]*\n/)[0];
const indexHtml=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');

/* Exclusive of `end`, like the sibling suites. */
const section=(start,end,source=appJs)=>{
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing section ${start} … ${end}`);
  return source.slice(from,to);
};
/* Inclusive of `end`, for whole statements. */
const statement=(start,end,source=appJs)=>{
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing statement ${start} … ${end}`);
  return source.slice(from,to+end.length);
};

const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money=cents=>`SGD ${(Number(cents||0)/100).toFixed(2)}`;

/* ---------------------------------------------------------------- 1. customer profile ------- */

/* The row builder and the three V319 helpers that feed it, evaluated exactly as they ship. Their
   inputs (the balance, the expiry slice, which programme the firm runs) are injected, because the
   whole question this suite answers is what the counter reads for a GIVEN customer. */
const customerHarness=({pts,cred,nextExp,prog,loyaltyFactsAvailable=true,pointsMode='redeem'})=>new Function(
  'esc','pts','cred','nextExp','prog','loyaltyFactsAvailable','pointsModeV319','money','CUI',`
  ${STATUS_PRELUDE_SRC}
  const pointsUnit=prog?.unit==='stamps'?'stamps':'points';
  ${statement('const balanceProgrammeRowV319=','\'points\');')}
  ${statement('const pointsExpiryPhraseV319=(()=>{','})();')}
  ${statement('const pointsHistoryButtonV319=','</button>\`;')}
  ${statement('const programmeRowHtmlV294=','</span></div>\`;')}
  const balanceLeadHtmlV319=(unitWord,tail)=>\`\${pointsHistoryButtonV319} \${esc(unitWord)}\${esc(pointsExpiryPhraseV319)}\${esc(tail)}\`;
  return {balanceProgrammeRowV319,pointsExpiryPhraseV319,pointsHistoryButtonV319,
    programmeRowHtmlV294,balanceLeadHtmlV319,pointsUnit};`)(
  esc,pts,cred,nextExp,prog,loyaltyFactsAvailable,pointsMode,money,{icon:()=>''});

const LIVE_POINTS={unit:'points',active:true,earn_points_per_dollar:1};

test('V319 the Points System row states the balance and when it expires', () => {
  const h=customerHarness({pts:300,cred:0,prog:LIVE_POINTS,
    nextExp:{remaining:300,expires_at:'2026-09-20T00:00:00+08:00'}});
  const row=h.programmeRowHtmlV294('Points System','',true,null,
    h.balanceLeadHtmlV319(h.pointsUnit,' · 700 more for Free Facial cream'));
  assert.match(row,/>Points System</);
  assert.match(row,/>300</,'the balance the owner circled must be on the row');
  /* Sep / Sept is the runtime's ICU, not ours — this is the SAME formatter the V249 expiry line
     has always used, so the row cannot disagree with the collapsible beneath it. */
  assert.match(row,/expires 20 Sept? 2026/,'"expires in xxx" — the row must say when');
  assert.match(row,/700 more for Free Facial cream/,'the next milestone is not displaced by the expiry');
  /* The number stays the way into the points ledger (V259: "not clickable to see where the points
     came from"), and there is exactly one such control on the page. */
  assert.equal((row.match(/id="c360PointsHistoryV259"/g)||[]).length,1);
});

test('V319 a partial expiry says how much expires, never implying the whole balance goes', () => {
  const whole=customerHarness({pts:300,cred:0,prog:LIVE_POINTS,
    nextExp:{remaining:300,expires_at:'2026-09-20T00:00:00+08:00'}});
  assert.match(whole.pointsExpiryPhraseV319,/^ · expires 20 Sept? 2026$/);
  const part=customerHarness({pts:300,cred:0,prog:LIVE_POINTS,
    nextExp:{remaining:120,expires_at:'2026-09-20T00:00:00+08:00'}});
  assert.match(part.pointsExpiryPhraseV319,/120 points expire 20 Sept? 2026/);
  assert.doesNotMatch(part.pointsExpiryPhraseV319,/^ · expires/,
    'a partial expiry must not read as though all 300 points go');
  /* Nothing scheduled to expire adds nothing — no "no expiry" filler on the row. */
  assert.equal(customerHarness({pts:300,cred:0,prog:LIVE_POINTS,nextExp:null}).pointsExpiryPhraseV319,'');
});

test('V319 the summary card only drops the points row when a programme row took it over', () => {
  /* Points firm: a Points System row exists, so the duplicated summary row is the one struck out. */
  assert.equal(customerHarness({pts:300,cred:0,prog:LIVE_POINTS,nextExp:null}).balanceProgrammeRowV319,'points');
  /* Stamps firm: the Stamp card row carries it. */
  assert.equal(customerHarness({pts:8,cred:0,prog:{unit:'stamps',active:true},nextExp:null}).balanceProgrammeRowV319,'stamps');
  /* Tiers-only: there is NO Points System row, so nothing moved and the summary row must stay —
     otherwise this firm's owner loses the balance and the points history with it. */
  assert.equal(customerHarness({pts:300,cred:0,prog:LIVE_POINTS,nextExp:null,pointsMode:'tiers'}).balanceProgrammeRowV319,null);
  /* No programme at all, and an unreadable loyalty facet: same rule, both keep the row. */
  assert.equal(customerHarness({pts:0,cred:0,prog:null,nextExp:null}).balanceProgrammeRowV319,null);
  assert.equal(customerHarness({pts:0,cred:0,prog:LIVE_POINTS,nextExp:null,loyaltyFactsAvailable:false}).balanceProgrammeRowV319,null);
});

test('V319 a paused programme still explains its 0, at the place the 0 is printed', () => {
  const h=customerHarness({pts:0,cred:0,prog:{unit:'points',active:false},nextExp:null});
  const pausedNote=section('const pointsPausedNoteV259=','const pointsUnit=');
  assert.match(pausedNote,/customer360-points-paused-v259/);
  const row=h.programmeRowHtmlV294('Points System','',false,null,
    h.balanceLeadHtmlV319(h.pointsUnit,''),
    '<p class="muted small customer360-points-paused-v259">Programme paused</p>');
  assert.match(row,/pill off">Off</);
  assert.match(row,/customer360-points-paused-v259/);
  /* The note is a SIBLING of the copy paragraph, never nested inside it — a <p> inside a <p> is
     auto-closed by the parser and the row would come apart in a real browser. */
  const copyParagraph=row.slice(row.indexOf('<p class="muted small" data-merchant-content>'));
  assert.ok(copyParagraph.indexOf('</p>')<copyParagraph.indexOf('<p class="muted small customer360'),
    'the paused note must open only after the copy paragraph has closed');
});

test('V319 the row builder still escapes every caller that did not opt into markup', () => {
  const h=customerHarness({pts:0,cred:0,prog:LIVE_POINTS,nextExp:null});
  const injected=h.programmeRowHtmlV294('<script>x</script>','<img src=x onerror=1>',true);
  assert.doesNotMatch(injected,/<script>/);
  assert.doesNotMatch(injected,/<img /);
  assert.match(injected,/&lt;script&gt;/);
});

test('V319 promotions leave the programmes card for a box of their own', () => {
  const build=section('const limitedOfferRowsV319=','if(referralProgrammeV294)');
  /* Same rows, same shape, same source — only the card they land in changed. */
  assert.match(build,/promotionsV294\|\|\[\]/);
  assert.match(build,/filter\(item=>item\?\.active===true\)/);
  assert.match(build,/slice\(0,6\)/);
  assert.match(build,/programmeRowHtmlV294\(item\.name\|\|'Promotion'/);
  /* And they are no longer pushed into the programmes list. */
  const programmesList=section('const programmeRowsV294=[];','const programmesListV294=');
  assert.doesNotMatch(programmesList,/programmeRowsV294\.push\(programmeRowHtmlV294\(item\.name/);

  const card=statement('const limitedOfferCardV319=','\'\';');
  assert.match(card,/limitedOfferRowsV319\.length/,'absent stays absent — no empty offers card');
  assert.match(card,/id="c360-offers-v319"/);
  assert.match(card,/<b>Limited offers<\/b>/);
  /* Distinct from, and rendered after, the programmes card the owner kept — and after the
     summary card, whose upper-right slot two prior owner reviews signed off. These grid cells
     are auto-placed in DOM order, so inserting the box earlier silently moves the summary. */
  const layout=section('<div class="split c360-content-split-v295"','${retentionMarkup}');
  assert.ok(layout.indexOf('Available Customer Programmes')<layout.indexOf('summaryCardV294'));
  assert.ok(layout.indexOf('summaryCardV294')<layout.indexOf('limitedOfferCardV319'));
  assert.match(layout,/canReadLoyalty\?limitedOfferCardV319:''/,
    'the offers box inherits the same loyalty read gate as the card it left');
});

/* ------------------------------------------------------------------ 2. programmes module ----- */

/* v401: the row builder now asks CUI for a 16px kind mark, so the harness has to supply one. The
   stub prints the glyph NAME rather than a path, which is what lets the assertions below check that
   a parent row is marked with the right kind and a child row is not marked at all. */
const growHarness=()=>new Function('esc','assertOk','CUI',`
  ${STATUS_PRELUDE_SRC}
  ${statement('function promotionDateTextV104(value){','\n}')}
  ${statement('function promotionDateShortV324(value){','\n}')}
  ${statement('const growCountCellV271=','esc(String(Number(value)));')}
  ${statement('const growDateCellV271=','\'<span class="muted">Not tracked</span>\';')}
  ${statement('const growTableV271=','\`<div class="empty" role="status">\${empty}</div>\`;')}
  const growUsageV271={};
  return (rewardRows,offerRows)=>{
    const growOverviewRowsV271=[...rewardRows,...offerRows];
    ${statement('const growLimitedOfferEntryV319=','growOverviewRowsV271.filter(growLimitedOfferEntryV319);')}
    ${statement('const growOverviewChildRowV324=','\`\${nameV388}\${parentNote}\`;\n  }];')}
    ${statement('const growOverviewRewardsTableV319=','esc(row.detail)}</span>\`:\'<span class="muted">—</span>\']]});')}
    ${statement('const growOverviewOffersTableV319=','esc(row.detail)}</span>\`:\'<span class="muted">—</span>\']]});')}
    ${statement('const growOverviewFrameV324=','</div>\`;')}
    ${statement('const growOverviewTableV271=growOverviewFrameV324(','});')}
    return {html:growOverviewTableV271,rewards:growOverviewRewardRowsV319,offers:growOverviewOfferRowsV319};
  };`)(esc,null,{icon:name=>`<svg data-icon-v401="${name}"></svg>`});

const REWARD_ROW={name:'Point system',type:'Point system',started:'2026-07-21T00:00:00+08:00',
  ended:null,endsAt:null,state:'live',customers:3,detail:'SGD 1 spent → 1 point'};
const OFFER_ROW={name:'National Day: 50% off first prata',type:'Promotion',
  started:'2026-08-07T00:00:00+08:00',ended:null,endsAt:'2026-08-31T23:59:59+08:00',
  state:'live',customers:null,detail:'Celebrate National Day'};

test('V319 Overview is two categories side by side, split by what a row actually is', () => {
  const build=growHarness();
  const {html,rewards,offers}=build([REWARD_ROW],[OFFER_ROW]);
  assert.deepEqual(rewards.map(r=>r.name),['Point system']);
  assert.deepEqual(offers.map(r=>r.name),['National Day: 50% off first prata']);
  assert.match(html,/data-grow-overview-category-v319="rewards"/);
  assert.match(html,/data-grow-overview-category-v319="offers"/);
  assert.match(html,/Rewards &amp; Loyalty/);
  assert.match(html,/>Limited Offer</);
  /* Left column first, as the owner drew them. */
  assert.ok(html.indexOf('="rewards"')<html.indexOf('="offers"'));
  /* Neither row appears under the other's heading. */
  const rewardsHalf=html.slice(html.indexOf('="rewards"'),html.indexOf('="offers"'));
  assert.doesNotMatch(rewardsHalf,/National Day/);
  assert.match(html.slice(html.indexOf('="offers"')),/National Day/);
});

test('V319 the offers table drops a count nothing records and states when the offer stops', () => {
  const {html}=growHarness()([REWARD_ROW],[OFFER_ROW]);
  const offersHalf=html.slice(html.indexOf('="offers"'));
  assert.doesNotMatch(offersHalf,/Customers used/,
    'a column that can only ever say "Not tracked" is not a column');
  assert.doesNotMatch(offersHalf,/Not tracked/);
  assert.match(offersHalf,/<th>Ends<\/th>/);
  /* V324 (owner: "all date use dd/mm/yyyy format"). Still the house date cell and still the same
     instant — Singapore, noon-anchored — so this pins the FORMAT change without loosening the
     rule the V319 author wrote this line for: both date columns come from one formatter. */
  assert.match(offersHalf,/31\/08\/2026/,'the end date comes from the house date cell, in the owner\'s format');
  assert.doesNotMatch(offersHalf,/31 August 2026/,'the long form is what the owner struck out');
  /* The rewards side keeps every column the V271 and V301 owners named, MINUS Type, which the
     owner struck through on 2026-08-14 — see the V324 child-indent test below for what now
     carries the relationship that column used to state. */
  const rewardsHalf=html.slice(html.indexOf('="rewards"'),html.indexOf('="offers"'));
  for(const column of ['Programme','Started','Customers used','Setting'])
    assert.match(rewardsHalf,new RegExp(`<th>${column}</th>`));
  assert.doesNotMatch(rewardsHalf,/<th>Type<\/th>/,'the owner struck the Type column');
});

test('V319 an open-ended offer says so rather than borrowing a count\'s "Not tracked"', () => {
  const {html}=growHarness()([],[{...OFFER_ROW,endsAt:null}]);
  assert.match(html,/No end date/);
  assert.doesNotMatch(html,/Not tracked/);
});

test('V319 each category empties independently, and points at its own door', () => {
  const onlyOffers=growHarness()([],[OFFER_ROW]).html;
  assert.match(onlyOffers,/No reward programme is running yet/);
  assert.match(onlyOffers,/National Day/);
  const onlyRewards=growHarness()([REWARD_ROW],[]).html;
  assert.match(onlyRewards,/No offer is running yet/);
  assert.match(onlyRewards,/href="#\/grow\/offers"/);
  assert.match(onlyRewards,/Point system/);
});

/* V324 — the owner's 2026-08-14 markup over this same table. Each assertion is the mark itself:
   the struck Type column, the ringed reward row ("those reward is under point system"), the
   ringed "+" beside each heading, and the arrow onto the date column. */

/* V388: a row carries the editor it opens (openV388), set where the row was built. */
const CHILD_REWARD_ROW={name:'Free Facial cream',type:'Reward',started:'2026-08-06T00:00:00+08:00',
  ended:null,endsAt:null,state:'live',customers:0,detail:'1000 points',
  openV388:{topic:'gift',id:'reward-1',kind:'points'}};

test('V324 a reward reads as belonging to the programme above it, not as its sibling', () => {
  const {html}=growHarness()([REWARD_ROW,CHILD_REWARD_ROW],[]);
  const rewardsHalf=html.slice(html.indexOf('="rewards"'));
  /* Read the two name cells rather than slicing the string: the indent is an element that OPENS
     before the name it wraps, so any assertion cut at the name itself lands inside the markup it
     is trying to judge and reports the child's own tag against the parent. */
  const cells=[...rewardsHalf.matchAll(/<td data-label="Programme">([\s\S]*?)<\/td>/g)].map(m=>m[1]);
  assert.equal(cells.length,2);
  /* Order comes from how the entries were built — parent first, child after — because the indent
     claims subordination to the row above and nothing else. */
  assert.match(cells[0],/Point system/);
  assert.match(cells[1],/Free Facial cream/);
  /* The child is indented; the programme it sits under is NOT. That contrast is the whole point —
     an indent applied to every row says nothing. */
  assert.doesNotMatch(cells[0],/grow-overview-child-v324/,'the Point system row is a parent and takes no indent');
  /* V385: the indent is a real \u21b3 glyph in the markup now, not a CSS ::before elbow that a
     narrow-screen media query deleted — on a tablet the gifts were not indented at all. */
  /* V388 (owner, photo 4): the name is the control that opens this reward's own editor, so it is
     a button rather than a <b>. The indent and the arrow are unchanged. */
  /* v401: the name control is wrapped in .grow-overview-name-v401 so that the kind mark and the
     name stay one inline unit. Below 768px the responsive table makes each cell a display:grid
     block with the column name as a ::before, and two sibling nodes there become two grid ROWS —
     the mark detached from its name and sat on a line of its own. */
  assert.match(cells[1],/<span class="grow-overview-child-v324"><span class="grow-overview-arrow-v385" aria-hidden="true">\u21b3<\/span><span class="grow-overview-name-v401"><button type="button" class="grow-overview-open-v388"[^>]*>Free Facial cream<\/button><\/span><\/span>/);
  /* v401: and a child carries NO kind mark. The indent arrow beside it already says whose row it
     is, so a mark here would be the same information twice — this is the rule that keeps the
     column from turning into a badge list. */
  assert.doesNotMatch(cells[1],/grow-overview-row-mark-v401/,'a child reward row takes no kind mark');
  assert.match(cells[0],/grow-overview-row-mark-v401/,'a parent programme row carries its kind mark');
  assert.match(cells[0],/data-icon-v401="star"/,'the Point system row is marked with the points glyph');
  /* The button carries WHICH editor and WHICH row, so the handler never infers either from the
     label — a firm that renames a gift still opens that gift. */
  assert.match(cells[1],/data-grow-open-v388="gift"/);
  assert.match(cells[1],/data-grow-open-id-v388="reward-1"/);
  assert.match(cells[1],/data-grow-open-kind-v388="points"/,'a stamp-card gift must not open the points template');
  /* And a row with no editor stays plain text rather than becoming a button that goes nowhere. */
  const plain=growHarness()([{...CHILD_REWARD_ROW,openV388:undefined}],[]);
  assert.doesNotMatch(plain.html,/grow-overview-open-v388/);
});

test('V324 with no programme above it, a lone reward is not indented under nothing', () => {
  /* The case History actually produces: a firm retires three rewards and never retires the points
     programme, so the table is all children. An indent there points at a parent that is not on
     the screen — the elbow has to be earned by a row above it, not by the row's own type. */
  const {html}=growHarness()([CHILD_REWARD_ROW,{...CHILD_REWARD_ROW,name:'Free Lotion'}],[]);
  assert.doesNotMatch(html,/grow-overview-child-v324/);
  assert.match(html,/Free Facial cream/);
  assert.match(html,/Free Lotion/);
});

test('V324 a promotion is never indented — the child rule is scoped to rewards', () => {
  const {html}=growHarness()([REWARD_ROW],[OFFER_ROW]);
  const offersHalf=html.slice(html.indexOf('="offers"'));
  assert.doesNotMatch(offersHalf,/grow-overview-child-v324/);
});

test('V324 each column heading carries its own add control, pointing at its own editor', () => {
  const {html}=growHarness()([REWARD_ROW],[OFFER_ROW]);
  const rewardsHalf=html.slice(html.indexOf('="rewards"'),html.indexOf('="offers"'));
  const offersHalf=html.slice(html.indexOf('="offers"'));
  assert.match(rewardsHalf,/class="btn ghost sm grow-overview-add-v324" href="#\/grow"/);
  assert.match(offersHalf,/class="btn ghost sm grow-overview-add-v324" href="#\/grow\/offers"/);
  /* A "+" alone is not a label. The owner's low-literacy-first rule (CLAUDE.md) is why the
     accessible name has to say what is being added, in words, on each one. */
  assert.match(rewardsHalf,/aria-label="Add another reward programme"/);
  assert.match(offersHalf,/aria-label="Add another limited offer"/);
});

test('V324 the Started column is dd/mm/yyyy, on both categories', () => {
  const {html}=growHarness()([REWARD_ROW],[OFFER_ROW]);
  assert.match(html,/21\/07\/2026/,'21 July 2026, as the owner asked to see it');
  assert.match(html,/07\/08\/2026/);
  assert.doesNotMatch(html,/21 July 2026/);
  assert.doesNotMatch(html,/7 August 2026/);
});

test('V319 the rail says Rewards & Offer, and Limited Offer is a real routable child', () => {
  const group=statement("{key:'grow',icon:'star'","['History','#/grow/history','waitlist']]},");
  assert.match(group,/label:'Rewards & Offer'/);
  assert.doesNotMatch(group,/label:'Programmes'/);
  assert.match(group,/\['Rewards Programme','#\/grow','star'\]/);
  assert.match(group,/\['Limited Offer','#\/grow\/offers','tag'\]/);
  assert.doesNotMatch(group,/\['List','#\/grow','star'\]/);
  /* The module gate is untouched — renaming a rail group must not change who can see it. */
  assert.match(group,/items:\['loyalty','retention','referrals','memberships'\]/);
});

test('V319 #/grow/offers resolves as a view, lights one rail row, and renders only offers', () => {
  /* V371: one frozen constant feeds both the view resolver and the deep-link guard — see
     v366-bringback-route-reachability.test.mjs, which executes both out of the shipped source. */
  assert.match(appJs,/const GROW_PROGRAMME_VIEWS_V371=Object\.freeze\(\[[^\]]*'offers'[^\]]*\]\);/);
  assert.match(appJs,/const programmeView=GROW_PROGRAMME_VIEWS_V371\.includes\(String\(hashParam\|\|''\)\)\?String\(hashParam\):'list'/);
  assert.match(appJs,/const hashParamIsProgrammeView=GROW_PROGRAMME_VIEWS_V371\.includes\(String\(hashParam\|\|''\)\);/,
    'without this the hash is handed to the deep editor instead of the view');
  /* V375 added 'bringback' to the same list, for the same reason — see photo 9. */
  assert.match(appJs,/const growCategoryViewV271=!\['overview','history','setup','offers','points','tiers','bringback','birthday'\]/,
    'without this the offers view falls through to "render every category"');
  /* Rail active-state: 'offers' belongs to its own child, not to the Rewards Programme list. */
  const navActive=section('const navViewActiveV296=','const childRowsV294=');
  assert.match(navActive,/!\['overview','history','offers'\]\.includes\(String\(page\[1\]\|\|''\)\)/);
  /* The heading follows the rail's words. */
  assert.match(appJs,/programmeView==='offers'\?'Limited Offer'/);
  assert.match(appJs,/'Set up rewards':'Rewards Programme'/);
});

test('V319 the drilled topic and the Limited Offer tab render one definition, not two copies', () => {
  assert.equal((appJs.match(/const growLimitedOfferCategoryHtmlV319=/g)||[]).length,1);
  assert.match(appJs,/\$\{topicOnV229\('promotions'\)\?growLimitedOfferCategoryHtmlV319:''\}/);
  assert.match(appJs,/programmeView==='offers'\?`<div class="grow-limited-offer-v319"/);
  /* "editable in this tab" — every promotion row keeps its owner-gated Edit destination. */
  const category=statement('const growLimitedOfferListHtmlV319=','actionLabel:\'Set up\'})}`;');
  assert.match(category,/href:`#\/promotions\/\$\{encodeURIComponent\(item\.id\)\}`,actionLabel:'Edit'/);
  assert.match(category,/href:'#\/promotions',actionLabel:'Set up'/);
  assert.match(category,/canWrite:isOwner&&canRewards,readOnly:canRewards&&!isOwner/);
});

/* ---------------------------------------------------------------------- 3. dashboard --------- */

test('V319 the period strip left the page titlebar for the Performance card', () => {
  /* Comments stripped first: this titlebar carries a V319 note that NAMES the class it no longer
     renders, and an assertion that a comment can satisfy is no assertion. */
  const titlebar=section('<header class="v150-titlebar">','</header>')
    .replace(/<!--[\s\S]*?-->/g,'').replace(/\/\*[\s\S]*?\*\//g,'');
  assert.doesNotMatch(titlebar,/dashboard-range/,'the strip no longer filters the whole page');
  assert.doesNotMatch(titlebar,/data-d="/);
  assert.doesNotMatch(titlebar,/id="apply"/);

  const heading=statement('<header class="performance-heading ux154-collapsible-head">','</header>');
  assert.match(heading,/class="dashboard-range dashboard-range-v319"/);
  for(const days of ['1','7','30','90'])assert.match(heading,new RegExp(`data-d="${days}"`));
  assert.match(heading,/id="df"/);assert.match(heading,/id="dt"/);assert.match(heading,/id="apply"/);
  /* Beside the period line it rewrites, and before Minimise. */
  assert.ok(heading.indexOf('id="dashboardPerformancePeriod"')<heading.indexOf('dashboard-range-v319'));
  assert.ok(heading.indexOf('dashboard-range-v319')<heading.indexOf('id="dashboardPerformanceToggle"'));
  /* Outside the collapsible body: minimising the figures must not take the control with them,
     because it also moves the schedule day (V295's two-way link). */
  const body=section('<div class="performance-body ux154-collapsible-body"','</section>');
  assert.doesNotMatch(body,/dashboard-range/);
});

test('V319 moving the strip did not detach a single handler', () => {
  const dash=section('async function dashboard(){','function normalizeSingaporeCustomerSearch(');
  /* Every wiring site still resolves through dashboardRoot / $(), both of which contain the new
     position exactly as they contained the old one. */
  assert.match(dash,/dashboardRoot\.querySelectorAll\('\.qbtn\[data-d\]'\)/);
  assert.match(dash,/dashboardRoot\.querySelectorAll\('\.dashboard-range input\[type="date"\]'\)/);
  assert.match(dash,/\$\('apply'\)|dashboardRoot\.querySelector\('#apply'\)|getElementById\('apply'\)/);
  /* Exactly one of each control on the page — a move that left a copy behind would wire the
     first and leave the owner pressing the second. */
  const view=statement('M().innerHTML=`<section id="dashboardView"','<div id="dashboardInsights" aria-live="polite"></div></section>`;');
  assert.equal((view.match(/id="apply"/g)||[]).length,1);
  assert.equal((view.match(/id="df"/g)||[]).length,1);
  assert.equal((view.match(/class="dashboard-range/g)||[]).length,1);
  assert.equal((view.match(/data-d="30"/g)||[]).length,1);
});

test('V319 the relocated strip has somewhere to sit at every width', () => {
  /* The heading was nowrap flex above 390px, which would have squeezed the date pair. */
  assert.match(indexHtml,/\.performance-heading\{[^}]*flex-wrap:wrap/);
  assert.match(indexHtml,/\.performance-heading>\.dashboard-range-v319\{margin-left:auto/);
  assert.match(indexHtml,/@media\(max-width:900px\)\{\.performance-heading>\.dashboard-range-v319\{order:3;flex-basis:100%/);
  /* The two Overview columns are unequal (five columns beside four) and stack before either
     table has to break a word across lines. */
  assert.match(indexHtml,/\.grow-overview-split-v319\{display:grid;grid-template-columns:minmax\(0,1\.15fr\) minmax\(0,0\.85fr\)/);
  assert.match(indexHtml,/@media\(max-width:1200px\)\{\.grow-overview-split-v319\{grid-template-columns:minmax\(0,1fr\)\}\}/);
  /* Only the two-table view widens; every other Rewards & Offer view keeps its 920px measure. */
  assert.match(indexHtml,/\.grow-overview\[data-programme-view="overview"\]\{max-width:1280px\}/);
});

/* --------------------------------------------------------------------- shipped bundles ------- */

test('V319 every attribute this wave emits is read back with the casing the DOM gives it', () => {
  /* W6 increment 2 shipped four dead toggles because a handler read dataset.growSetupSwitchW6I2
     while the DOM spells the attribute growSetupSwitchW6i2. These three attributes are test hooks
     with no dataset reader at all — this asserts that stays true, so the trap cannot reopen. */
  for(const attribute of ['grow-overview-split-v319','grow-overview-category-v319','grow-limited-offer-v319']){
    const camel=attribute.replace(/-([a-z])/g,(_,c)=>c.toUpperCase());
    assert.match(appJs,new RegExp(`data-${attribute}`),`${attribute} must be emitted`);
    assert.doesNotMatch(appJs,new RegExp(`dataset\\.${camel}`,'i'),
      `${attribute} gained a dataset reader — pin the exact casing before relying on it`);
  }
});

test('V319 the shipped business bundle carries all three changes', () => {
  const bundle=readFileSync(new URL('../../app/app-business.js',import.meta.url),'utf8');
  assert.match(bundle,/label:'Rewards & Offer'/);
  assert.match(bundle,/\['Limited Offer','#\/grow\/offers','tag'\]/);
  assert.match(bundle,/data-grow-overview-category-v319="offers"/);
  assert.match(bundle,/dashboard-range dashboard-range-v319/);
  assert.match(bundle,/id="c360-offers-v319"/);
  assert.match(bundle,/pointsExpiryPhraseV319/);
});
