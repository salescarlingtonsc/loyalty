import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

/* nestly_v832 (owner, 2026-09-09), two asks against the Staff commission page:
     1. "Boss able to track individual sales (with breakdown on the sale) & filter accordingly."
     2. "Is there a tracker and analysis behind to show who is performing better? lesser deals but
        bigger payment size etc. I need insightful data analytics."
   The repo's rule is that source-regex tests are vacuous unless something is EXECUTED, so the two
   pure helpers that decide every number on the page — the filter both views run on, and the
   comparison behind the new card — are extracted and RUN here against rows shaped exactly like
   business_staff_commission_lines_v825 returns them: two members, an unattributed line, a
   reversed sale, a discount line and a bundle line. Only the markup that cannot be executed
   without a DOM is pinned by source. */

const app=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');

function statement(start,end){
  const from=app.indexOf(start);
  assert.ok(from>=0,`missing ${start}`);
  const to=app.indexOf(end,from+start.length);
  assert.ok(to>from,`unterminated ${start}`);
  return app.slice(from,to+end.length);
}

/* The helpers are one block, because the filter and the comparison share one kind classifier —
   a page that filtered "Bundles" differently from the way it reported the bundle share would be
   two answers to one question. */
function region(start,end){
  const from=app.indexOf(start);
  assert.ok(from>=0,`missing ${start}`);
  const to=app.indexOf(end,from+start.length);
  assert.ok(to>from,`missing ${end} after ${start}`);
  return app.slice(from,to);
}
const helperSource=region('const STAFF_COMMISSION_KINDS_V832=[','\nfunction commissionInputsHtmlV825(');
const H=new Function(`${helperSource};return {STAFF_COMMISSION_KINDS_V832,staffCommissionKindKeyV832,`
  +'staffCommissionFilterV832,staffCommissionInsightsV832,staffCommissionMixTextV832,'
  +'staffCommissionInsightLineV832}')();

const cash=cents=>`$${(Number(cents)/100).toFixed(2)}`;

/* One period of a two-chair shop. Jeff rings up many small tickets; Mei rings up one big bundle;
   one line was never attributed to anybody; one whole sale was reversed. */
const ROWS=[
  {sale_id:'sale-1',line_id:'l1',occurred_at:'2026-09-09T02:00:00+00:00',client_id:'c1',client_name:'Ann',
   staff_id:'staff-a',staff_name:'Jeff',item_type:'service',description:'Haircut',qty:1,
   line_cents:5000,commission_cents:500,rate_bps:1000,flat_cents:null,bundle_id:null,sale_kind:'service',reversed:false},
  {sale_id:'sale-1',line_id:'l2',occurred_at:'2026-09-09T02:00:00+00:00',client_id:'c1',client_name:'Ann',
   staff_id:'staff-a',staff_name:'Jeff',item_type:'retail',description:'Shampoo',qty:2,
   line_cents:3000,commission_cents:300,rate_bps:1000,flat_cents:null,bundle_id:null,sale_kind:'service',reversed:false},
  {sale_id:'sale-1',line_id:'l3',occurred_at:'2026-09-09T02:00:00+00:00',client_id:'c1',client_name:'Ann',
   staff_id:'staff-a',staff_name:'Jeff',item_type:'studio_discount',description:'Member discount',qty:1,
   line_cents:-1000,commission_cents:0,rate_bps:null,flat_cents:null,bundle_id:null,sale_kind:'service',reversed:false},
  {sale_id:'sale-2',line_id:'l4',occurred_at:'2026-09-09T01:00:00+00:00',client_id:'c2',client_name:'Ben',
   staff_id:'staff-a',staff_name:'Jeff',item_type:'service',description:'Haircut',qty:1,
   line_cents:4000,commission_cents:400,rate_bps:1000,flat_cents:null,bundle_id:null,sale_kind:'service',reversed:false},
  {sale_id:'sale-3',line_id:'l5',occurred_at:'2026-09-08T05:00:00+00:00',client_id:'c3',client_name:'Cara',
   staff_id:'staff-b',staff_name:'Mei',item_type:'service',description:'Spa bundle',qty:1,
   line_cents:20000,commission_cents:2000,rate_bps:1000,flat_cents:null,bundle_id:'bundle-1',sale_kind:'quick_sale',reversed:false},
  {sale_id:'sale-4',line_id:'l6',occurred_at:'2026-09-08T04:00:00+00:00',client_id:null,client_name:null,
   staff_id:null,staff_name:null,item_type:'custom',description:'Misc charge',qty:1,
   line_cents:1500,commission_cents:0,rate_bps:null,flat_cents:null,bundle_id:null,sale_kind:'quick_sale',reversed:false},
  {sale_id:'sale-5',line_id:'l7',occurred_at:'2026-09-07T03:00:00+00:00',client_id:'c4',client_name:'Dee',
   staff_id:'staff-b',staff_name:'Mei',item_type:'service',description:'Facial',qty:1,
   line_cents:99900,commission_cents:9990,rate_bps:1000,flat_cents:null,bundle_id:null,sale_kind:'service',
   reversed:true,reversal_reason:'Cancelled'}
];

// --------------------------------------------------------------- the classifier

test('v832 a bundle line is a bundle whatever its own item_type says',()=>{
  const key=H.staffCommissionKindKeyV832;
  assert.equal(key(ROWS[4]),'bundle','a bundle member line is not reported as a service');
  assert.equal(key(ROWS[0]),'service');
  assert.equal(key(ROWS[1]),'product');
  assert.equal(key(ROWS[2]),'discount');
  assert.equal(key(ROWS[5]),'custom');
  assert.equal(key({item_type:'package'}),'package');
  assert.equal(key({item_type:'package_session'}),'package');
  assert.equal(key({item_type:'membership'}),'other');
  assert.equal(key({item_type:'gift_card'}),'other');
  assert.equal(key(null),'other');
  assert.deepEqual(H.STAFF_COMMISSION_KINDS_V832.map(k=>k.key),
    ['all','service','product','package','bundle','custom','discount','other'],
    'every kind the classifier can return is offered in the select');
});

// --------------------------------------------------------------- the comparison

test('v832 the comparison answers "lesser deals but bigger payment size" from the rows on screen',()=>{
  const {staff,team}=H.staffCommissionInsightsV832(ROWS);
  assert.deepEqual(staff.map(s=>s.key),['staff-b','staff-a','__unattributed'],
    'biggest seller first, and an unattributed line is never ranked among people');
  const jeff=staff.find(s=>s.key==='staff-a'),mei=staff.find(s=>s.key==='staff-b');
  // Jeff: two sales, one of them 5000+3000-1000 after its discount line
  assert.equal(jeff.name,'Jeff');
  assert.equal(jeff.sales,2,'three lines on one sale are ONE sale');
  assert.equal(jeff.lines,4);
  assert.equal(jeff.amount,11000,'the discount line pulls the amount down');
  assert.equal(jeff.commission,1200);
  assert.equal(jeff.avgSale,5500);
  assert.equal(jeff.biggestSale,7000,'the biggest ticket is a NET sale, not a line');
  assert.equal(jeff.effectiveRateBps,1091,'commission ÷ amount sold, rounded to basis points');
  assert.deepEqual(jeff.mix,{service:9000,product:3000,package:0,bundle:0,custom:0,discount:-1000,other:0});
  // Mei: one sale, far bigger — exactly the shape the owner asked to be able to see
  assert.equal(mei.sales,1);
  assert.equal(mei.amount,20000);
  assert.equal(mei.avgSale,20000);
  assert.equal(mei.biggestSale,20000);
  assert.equal(mei.effectiveRateBps,1000);
  assert.equal(mei.mix.bundle,20000);
  assert.equal(mei.mix.service,0,'the bundle line is counted once, as a bundle');
  // the reversed sale is worth $999 of commission and appears nowhere
  assert.ok(staff.every(s=>s.amount!==99900&&s.commission!==9990));
  assert.equal(team.amount,32500);
  assert.equal(team.commission,3200);
  assert.equal(team.sales,4,'a reversed sale is not a sale');
  assert.equal(team.lines,6);
  assert.equal(team.avgSale,8125);
  assert.equal(team.effectiveRateBps,985);
  // shares are of the team, and they add up
  assert.equal(Math.round(jeff.amountShare*10000),3385);
  assert.equal(Math.round(mei.amountShare*10000),6154);
  assert.ok(Math.abs(staff.reduce((t,s)=>t+s.amountShare,0)-1)<1e-9);
  assert.ok(Math.abs(staff.reduce((t,s)=>t+s.commissionShare,0)-1)<1e-9);
  assert.equal(Math.round(jeff.commissionShare*10000),3750);
});

test('v832 an unattributed line is listed last however much money it carries',()=>{
  const rows=ROWS.concat([{sale_id:'sale-9',line_id:'l9',occurred_at:'2026-09-06T00:00:00+00:00',
    staff_id:null,staff_name:null,item_type:'custom',description:'Cash sale',qty:1,
    line_cents:500000,commission_cents:0,bundle_id:null,sale_kind:'quick_sale',reversed:false}]);
  const {staff}=H.staffCommissionInsightsV832(rows);
  assert.equal(staff.at(-1).key,'__unattributed');
  assert.equal(staff.at(-1).name,'Unattributed');
  assert.equal(staff.at(-1).effectiveRateBps,0,'no commission on a big amount is a real 0%, not "unknown"');
});

test('v832 the comparison degrades to nothing rather than inventing a comparison',()=>{
  const empty=H.staffCommissionInsightsV832([]);
  assert.deepEqual(empty.staff,[]);
  assert.equal(empty.team.sales,0);
  assert.equal(empty.team.avgSale,0);
  assert.equal(empty.team.effectiveRateBps,null,'no amount sold means no rate, never 0%');
  assert.equal(H.staffCommissionInsightLineV832(empty,cash),'','nobody to compare');
  const solo=H.staffCommissionInsightsV832(ROWS.filter(r=>r.staff_id==='staff-a'));
  assert.equal(H.staffCommissionInsightLineV832(solo,cash),'','one member is not a comparison');
  assert.equal(H.staffCommissionInsightsV832(ROWS.filter(r=>r.reversed)).staff.length,0,
    'a period of nothing but reversals compares nobody');
});

test('v832 the insight line names only people who are in these rows',()=>{
  const insights=H.staffCommissionInsightsV832(ROWS);
  const line=H.staffCommissionInsightLineV832(insights,cash);
  assert.equal(line,'Jeff closes the most sales (2); Mei has the biggest average sale ($200.00) — fewer deals, bigger tickets.');
  assert.doesNotMatch(line,/Unattributed/,'"Unattributed" is not a person and is never named');
  // when one member leads on both counts the sentence says so instead of contradicting itself
  const oneLeader=H.staffCommissionInsightsV832([
    {sale_id:'s1',staff_id:'a',staff_name:'Ada',item_type:'service',line_cents:9000,commission_cents:900},
    {sale_id:'s2',staff_id:'a',staff_name:'Ada',item_type:'service',line_cents:9000,commission_cents:900},
    {sale_id:'s3',staff_id:'b',staff_name:'Bo',item_type:'service',line_cents:1000,commission_cents:100}
  ]);
  assert.equal(H.staffCommissionInsightLineV832(oneLeader,cash),
    'Ada leads on both: the most sales (2) and the biggest average sale ($90.00).');  // a tie is not a lead (owner reads this line as a ranking)
  const tied=H.staffCommissionInsightsV832([
    {sale_id:'s1',staff_id:'a',staff_name:'Ada',item_type:'service',line_cents:9000,commission_cents:900},
    {sale_id:'s2',staff_id:'b',staff_name:'Bo',item_type:'service',line_cents:4000,commission_cents:400}
  ]);
  assert.equal(H.staffCommissionInsightLineV832(tied,cash),
    'Sales are level (1 each); Ada has the biggest average sale ($90.00).');
  const allTied=H.staffCommissionInsightsV832([
    {sale_id:'s1',staff_id:'a',staff_name:'Ada',item_type:'service',line_cents:9000,commission_cents:900},
    {sale_id:'s2',staff_id:'b',staff_name:'Bo',item_type:'service',line_cents:9000,commission_cents:900}
  ]);
  assert.equal(H.staffCommissionInsightLineV832(allTied,cash),
    'Sales are level (1 each) and so is the average sale ($90.00).');
});

test('v832 the mix names the two biggest kinds and keeps a discount visible',()=>{
  const {staff}=H.staffCommissionInsightsV832(ROWS);
  assert.equal(H.staffCommissionMixTextV832(staff.find(s=>s.key==='staff-a').mix),'Services 69% · Products 23%');
  assert.equal(H.staffCommissionMixTextV832(staff.find(s=>s.key==='staff-b').mix),'Bundles 100%');
  assert.equal(H.staffCommissionMixTextV832({service:1000,discount:-1000}),'Services 50% · Discounts 50%',
    'a discount is measured by size, not by sign, so it cannot hide');
  assert.equal(H.staffCommissionMixTextV832(null),'');
});

// --------------------------------------------------------------- the filter

test('v832 one filter drives both views, and a sale shows the lines that matched',()=>{
  const all=H.staffCommissionFilterV832(ROWS,{});
  assert.equal(all.rows.length,7);
  assert.deepEqual(all.sales.map(s=>s.sale_id),['sale-1','sale-2','sale-3','sale-4','sale-5'],
    'newest sale first, exactly as the flat list is ordered');
  const saleOne=all.sales[0];
  assert.equal(saleOne.shownLines,3);
  assert.equal(saleOne.hiddenLines,0);
  assert.equal(saleOne.amount,7000,'the sale header is the net of its lines');
  assert.equal(saleOne.commission,800);
  assert.deepEqual(saleOne.staffNames,['Jeff']);
  assert.equal(saleOne.client_name,'Ann');
  assert.equal(all.sales[3].staffNames[0],'Unattributed');
  assert.equal(all.sales[4].reversed,true,'a reversed sale stays listed, flagged');
  assert.equal(all.sales[0].reversed,false);
  // totals exclude every reversed line, in both views, from the same projection
  assert.equal(all.totals.amount,32500);
  assert.equal(all.totals.commission,3200);
  assert.equal(all.totals.sales,4);
  assert.equal(all.totals.lines,6);
  assert.equal(all.totals.reversedLines,1);
  assert.equal(all.totals.reversedSales,1);
});

test('v832 the item-kind filter shows a sale when any line matches and subtotals only those lines',()=>{
  const services=H.staffCommissionFilterV832(ROWS,{kind:'service'});
  assert.deepEqual(services.rows.map(r=>r.line_id),['l1','l4','l7'],
    'the bundle line is a bundle, so it is not a service');
  assert.deepEqual(services.sales.map(s=>s.sale_id),['sale-1','sale-2','sale-5']);
  const partial=services.sales[0];
  assert.equal(partial.shownLines,1);
  assert.equal(partial.totalLines,3);
  assert.equal(partial.hiddenLines,2,'the page must be able to say two lines are hidden');
  assert.equal(partial.amount,5000,'the subtotal covers the matching lines only');
  assert.equal(services.totals.hiddenLines,2);
  assert.deepEqual(H.staffCommissionFilterV832(ROWS,{kind:'bundle'}).rows.map(r=>r.line_id),['l5']);
  assert.deepEqual(H.staffCommissionFilterV832(ROWS,{kind:'discount'}).rows.map(r=>r.line_id),['l3']);
  assert.deepEqual(H.staffCommissionFilterV832(ROWS,{kind:'product'}).rows.map(r=>r.line_id),['l2']);
  assert.deepEqual(H.staffCommissionFilterV832(ROWS,{kind:'custom'}).rows.map(r=>r.line_id),['l6']);
  assert.deepEqual(H.staffCommissionFilterV832(ROWS,{kind:'other'}).rows,[]);
  assert.equal(H.staffCommissionFilterV832(ROWS,{kind:'all'}).rows.length,7);
});

test('v832 the search reads the customer and the item, case-insensitively',()=>{
  const item=H.staffCommissionFilterV832(ROWS,{search:'SHAM'});
  assert.deepEqual(item.rows.map(r=>r.line_id),['l2']);
  assert.equal(item.sales[0].hiddenLines,2);
  const customer=H.staffCommissionFilterV832(ROWS,{search:'ann'});
  assert.deepEqual(customer.rows.map(r=>r.line_id),['l1','l2','l3'],'a customer match brings the whole sale');
  assert.equal(customer.sales[0].hiddenLines,0);
  assert.equal(H.staffCommissionFilterV832(ROWS,{search:'   '}).rows.length,7,'blank space is not a filter');
  assert.equal(H.staffCommissionFilterV832(ROWS,{search:'nothing here'}).rows.length,0);
  // a walk-in with no customer name and no description is not matched by an empty needle trick
  assert.equal(H.staffCommissionFilterV832(ROWS,{search:'misc'}).rows.length,1);
});

test('v832 the chip, the kind and the search compose, and the summary totals reconcile with the rows shown',()=>{
  assert.deepEqual(H.staffCommissionFilterV832(ROWS,{staffKey:'staff-b'}).rows.map(r=>r.line_id),['l5','l7']);
  assert.deepEqual(H.staffCommissionFilterV832(ROWS,{staffKey:'__unattributed'}).rows.map(r=>r.line_id),['l6']);
  const combined=H.staffCommissionFilterV832(ROWS,{staffKey:'staff-a',kind:'service',search:'hair'});
  assert.deepEqual(combined.rows.map(r=>r.line_id),['l1','l4']);
  assert.equal(combined.totals.amount,9000);
  assert.equal(combined.totals.commission,900);
  assert.equal(combined.totals.sales,2);
  /* The reconciliation the owner actually sees: whatever is on screen, the four cards and the
     "Total counted" row are the sum of the rows below them. */
  for(const options of [{},{kind:'service'},{search:'ann'},{staffKey:'staff-b'},
      {staffKey:'staff-a',kind:'product'},{kind:'bundle',search:'spa'}]){
    const result=H.staffCommissionFilterV832(ROWS,options);
    const counted=result.rows.filter(r=>!r.reversed);
    assert.equal(result.totals.amount,counted.reduce((t,r)=>t+r.line_cents,0),JSON.stringify(options));
    assert.equal(result.totals.commission,counted.reduce((t,r)=>t+r.commission_cents,0),JSON.stringify(options));
    assert.equal(result.totals.lines,counted.length,JSON.stringify(options));
    assert.equal(result.totals.sales,new Set(counted.map(r=>r.sale_id)).size,JSON.stringify(options));
    // and every row shown belongs to exactly one of the sale groups
    assert.equal(result.sales.reduce((t,s)=>t+s.lines.length,0),result.rows.length,JSON.stringify(options));
    assert.equal(new Set(result.sales.map(s=>s.sale_id)).size,result.sales.length,'no sale is grouped twice');
    // the comparison behind the card is measured on the SAME rows
    const insights=H.staffCommissionInsightsV832(result.rows);
    assert.equal(insights.team.amount,result.totals.amount,JSON.stringify(options));
    assert.equal(insights.team.commission,result.totals.commission,JSON.stringify(options));
    assert.equal(insights.team.sales,result.totals.sales,JSON.stringify(options));
  }
  assert.deepEqual(H.staffCommissionFilterV832(null,{}).rows,[]);
  assert.deepEqual(H.staffCommissionFilterV832([null,undefined],{}).rows,[]);
});

// --------------------------------------------------------------- what the page draws

test('v832 the page offers By line / By sale, the two filters, and the comparison card',()=>{
  const page=statement('async function staffPerfPage(drillId){','\nfunction enhanceStaffMembersTabsV164(');
  // the toggle, defaulting to By sale
  assert.match(page,/<button type="button" class="qbtn" data-commission-view-v832="line" aria-pressed="false">By line<\/button>/);
  assert.match(page,/<button type="button" class="qbtn act" data-commission-view-v832="sale" aria-pressed="true">By sale<\/button>/);
  assert.match(page,/let commissionViewV832='sale',commissionKindV832='all',commissionSearchV832='',commissionLoadedV832=false;/);
  // the filters, built once outside the re-rendered region so typing keeps the caret
  assert.match(page,/id="staffCommissionKindV832"/);
  assert.match(page,/STAFF_COMMISSION_KINDS_V832\.map\(kind=>`<option value="\$\{esc\(kind\.key\)\}">\$\{esc\(kind\.label\)\}<\/option>`\)/);
  assert.match(page,/id="staffCommissionSearchV832"/);
  assert.match(page,/id="staffCommissionClearV832"/);
  assert.ok(page.indexOf('id="staffCommissionFiltersV832"')<page.indexOf('id="pbody"'),'the filters sit above the table');
  // both views and the cards read ONE filtered projection of the same rows
  assert.match(page,/const scoped=staffCommissionFilterV832\(rowsV825,\{staffKey:'all',kind:commissionKindV832,search:commissionSearchV832\}\);/);
  assert.match(page,/const view=staffCommissionFilterV832\(rowsV825,\{staffKey:selectedStaffV825,kind:commissionKindV832,search:commissionSearchV832\}\);/);
  assert.match(page,/const insights=staffCommissionInsightsV832\(scoped\.rows\);/);
  assert.match(page,/const picked=view\.totals;/,'the four cards are the filtered totals, not the period totals');
  assert.match(page,/const counted=visible\.filter\(r=>!r\.reversed\);/);
  assert.match(page,/commissionViewV832==='sale'\s*\n\s*\?saleViewHtmlV832\(view\.sales,sumAmount,sumCommission\)\s*\n\s*:lineViewHtmlV832\(visible,sumAmount,sumCommission\)/);
  // the by-sale view: a header row per sale, its lines indented beneath it in the SAME columns
  assert.match(page,/const commissionTableHeadV832='<thead><tr><th>When<\/th><th>Customer<\/th><th>Item<\/th><th>Team member<\/th><th class="num">Amount<\/th><th>Rate<\/th><th class="num">Commission<\/th><th>Status<\/th><\/tr><\/thead>';/,
    'both views draw the same columns, so switching view never moves a number to a new column');
  assert.match(page,/<tr class="staff-commission-sale-v832"\$\{sale\.reversed\?' style="opacity:\.6"':''\}>/);
  assert.match(page,/<tr class="staff-commission-sale-line-v832"/);
  assert.match(page,/<td data-label="Item" style="padding-left:26px"><span class="muted" aria-hidden="true">↳<\/span>/,
    'a line is indented under its sale');
  assert.match(page,/line\$\{sale\.hiddenLines===1\?'':'s'\} hidden by the current filter, so this subtotal covers only the lines shown\./);
  // reversed sales stay struck through and dimmed in the new view too
  assert.match(page,/\$\{sale\.reversed\?`<s>\$\{esc\(money\(sale\.commission\)\)\}<\/s>`/);
  /* NO colspan in either view. CUI.enhanceTables sets data-responsive="false" on any table that
     contains one and re-asserts it on every mutation, so a single colspan on the total row strands
     the whole table as a wide desktop grid on a phone — which is what the v825 table did. */
  assert.doesNotMatch(page,/colspan=/,'a colspan anywhere would take both views out of the responsive card layout');
  assert.match(page,/const totalRowV832=\(labelSpan,sumAmount,sumCommission\)=>`<tr class="total-row"><td data-label="Total"><b>Total counted<\/b><\/td>\$\{'<td><\/td>'\.repeat\(labelSpan-1\)\}/);
  // mobile convention kept on every new cell
  const labelled=page.match(/<td[^>]*data-label="[^"]+"/g)||[];
  assert.ok(labelled.length>=20,'every cell keeps its data-label for the responsive table');
  assert.doesNotMatch(page,/<td class="num">\$\{esc\(money\(r\.line_cents\)\)\}/,'no cell lost its data-label');
  // the comparison card
  assert.match(page,/<section class="card" id="staffCommissionCompareV832" hidden><\/section>/);
  assert.match(page,/function renderTeamComparisonV832\(insights\)\{/);
  assert.match(page,/const shown=selectedStaffV825==='all'\?insights\.staff:insights\.staff\.filter\(s=>s\.key===selectedStaffV825\);/);
  assert.match(page,/<th>Team member<\/th><th class="num">Sales<\/th><th class="num">Avg per sale<\/th><th class="num">Biggest sale<\/th><th class="num">Amount sold<\/th><th class="num">Share<\/th><th class="num">Commission<\/th><th class="num">Effective rate<\/th><th>Mix<\/th>/);
  assert.match(page,/compareRowV832\(insights\.team,selectedStaffV825==='all'\?'Whole team':'Team average',true\)/);
  assert.match(page,/const insight=staffCommissionInsightLineV832\(insights,money\);/);
  assert.match(page,/Amount sold is what customers actually paid on the lines attributed to each member, after discounts\. Effective rate = commission ÷ amount sold\./);
  assert.ok(page.indexOf('id="staffCommissionCompareV832"')<page.indexOf('id="pbody"'),'the comparison sits above the table');
  // and nothing else on the page moved
  assert.match(page,/data-commission-period-v825="today"/);
  assert.match(page,/id="reportScopeNoteV272"/);
  assert.match(page,/Ask the owner for finance access to see staff commission\./);
  assert.match(page,/One sale line pays one team member\. Reversed sales are shown for traceability and excluded from every total\./);
});
