import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

/* V386 — the owner's photo 7 of 2026-08-17: "filter by date" drawn across the "Customers who
 * used each programme" table, and "down here can put analytics by graph / chart comparison"
 * beneath it.
 *
 * These assertions EXECUTE the shipped helpers against realistic payloads rather than grepping
 * app.js for the lines they were written against — the same discipline the V319 suite next door
 * adopted after nineteen green source pins failed to notice four inert toggles.
 */

const appJs=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const indexHtml=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');
const migration=readFileSync(new URL('../../db/migrations/20260818_nestly_v386_dated_programme_usage.sql',import.meta.url),'utf8');
const canonical=readFileSync(new URL('../../supabase/migrations/20260818000003_nestly_v386_dated_programme_usage.sql',import.meta.url),'utf8');

const section=(start,end,source=appJs)=>{
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing section ${start} … ${end}`);
  return source.slice(from,to);
};
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const promotionDateShortV324=value=>value?String(value).split('-').reverse().join('/'):'';

/* The shipped helpers, evaluated exactly as they ship. Only `growProgrammeEntriesV271` is
   injected — it is built from a live snapshot. The CATEGORISER is taken from source rather than
   restated here: V392 changed how gifts are grouped and this suite sailed straight through it,
   green, because it was running its own copy of the rule instead of the product's. A stub of the
   function under test is not a test of it. */
const usageHarness=entries=>new Function('esc','entries',`
  const growProgrammeEntriesV271=entries;
  const growOverviewChildRowV324=row=>row.type==='Reward';
  ${section('  const growAnalyticsCategoryV385=','  const growAnalyticsRowsV375=')}
  return {rowsFrom:growAnalyticsRowsFromUsageV386,categoryOf:growAnalyticsCategoryV385};
`)(esc,entries);

/* V392: the label helper travels with the chart, from source — the legend names whichever basis
   the owner picked (period before / last month / last year). */
const chart=new Function('esc','promotionDateShortV324',`
  ${section('const GROW_USAGE_COMPARE_OPTIONS_V392=','function growUsageComparisonRangeV392(')}
  ${section('function growUsageComparisonChartV386(','const REPORT_SHARE_COLOURS_V297=')}
  return growUsageComparisonChartV386;
`)(esc,promotionDateShortV324);

/* One point system, two gifts under it, one promotion nothing can measure, one referral row. */
const ENTRIES=[
  {name:'Point system',type:'Point system',usageScopeV386:'point_system'},
  {name:'Free Lotion',type:'Reward',parent:'Point system',usageScopeV386:'reward',usageIdV386:'r1'},
  {name:'moisturizer',type:'Reward',parent:'Point system',usageScopeV386:'reward',usageIdV386:'r2'},
  {name:'National Day',type:'Promotion'},
  {name:'Referrals',type:'Referrals',usageScopeV386:'referrals'}
];
/* V468 (owner photo 4: "It should be number of times, not how many customers used. It can be
   same customer but multiple times used."). The server publishes BOTH figures now, and this block
   reads `uses`. The fixtures carry both, with uses deliberately HIGHER than customers where the
   same person came back — if the code ever silently fell back to `customers` these numbers would
   change and the assertions below would catch it, which a fixture carrying only one key could
   never do. */
const USAGE_NOW={point_system:{customers:3,uses:5},referrals:{customers:1,uses:2},
  rewards:[{reward_id:'r1',customers:2,uses:3},{reward_id:'r2',customers:1,uses:1}]};
const USAGE_BEFORE={point_system:{customers:4,uses:9},referrals:{customers:0,uses:0},
  rewards:[{reward_id:'r1',customers:1,uses:1},{reward_id:'r2',customers:0,uses:0}]};

test('V386 a windowed payload is read through each entry\'s own scope, not its label',()=>{
  const {rowsFrom}=usageHarness(ENTRIES);
  const rows=rowsFrom(USAGE_NOW);
  const by=Object.fromEntries(rows.map(row=>[row.category,row]));
  assert.equal(by['Point system'].uses,5);
  assert.equal(by['Point system'].programmes,1);
  /* V385 took the gifts out of the engine's own count; V392 takes each gift out separately
     (owner, photo 6: "take out each gift out"), because "Point system gifts · 11" still could not
     say WHICH gift a customer took. One row per gift, named, counted from the per-reward list. */
  assert.equal(by['Free Lotion'].uses,3);
  assert.equal(by['Free Lotion'].programmes,1);
  assert.equal(by['moisturizer'].uses,1);
  assert.equal(by['moisturizer'].programmes,1);
  assert.ok(!by['Point system gifts'],'gifts are no longer lumped into one row');
  /* V271's honesty rule survives it too — a promotion is unmeasurable, never a zero. */
  assert.equal(by['Promotion'].uses,null);
  assert.equal(by['Referrals'].uses,2);
});

test('V386 renaming a programme cannot detach it from its own figures',()=>{
  const renamed=ENTRIES.map(entry=>entry.usageScopeV386==='point_system'?{...entry,name:'Cub Points',type:'Point system'}:entry);
  const {rowsFrom}=usageHarness(renamed);
  assert.equal(rowsFrom(USAGE_NOW).find(row=>row.category==='Point system').uses,5);
});

test('V386 a payload that never arrived reads as Not tracked, never as zero',()=>{
  const {rowsFrom}=usageHarness(ENTRIES);
  /* The windowed read failing must not print a page of zeroes that says nobody used anything. */
  assert.ok(rowsFrom(null).every(row=>row.uses===null));
});

test('V386 the chart compares this period with the previous one when a window is set',()=>{
  const {rowsFrom}=usageHarness(ENTRIES);
  const rows=rowsFrom(USAGE_NOW);
  const previous=new Map(rowsFrom(USAGE_BEFORE).map(row=>[row.category,row.uses]));
  const html=chart(rows,previous,{previousFrom:'2026-06-19',previousTo:'2026-07-18',days:30,basis:'previous'});
  assert.match(html,/is-was-v386/,'a windowed chart carries a second series');
  assert.match(html,/This period against the one before it/);
  assert.match(html,/19\/06\/2026 – 18\/07\/2026/,'the previous window is named, not implied');
  /* V392 (owner, photo 6): the owner picks what to compare against — the period before, last
     month or last year — so the legend names the basis rather than always saying "Previous". */
  assert.match(html,/Period before · 19\/06\/2026/);
  /* Point system fell 9 -> 5. Both bars are scaled against the largest value across BOTH series,
     so a shorter bar always means a smaller number. */
  const widths=[...html.matchAll(/width:([\d.]+)%/g)].map(match=>Number(match[1]));
  assert.ok(widths.includes(100),'the peak value across both series anchors the axis');
  assert.ok(Math.max(...widths)<=100);
  /* An unmeasurable category is left out of the chart rather than drawn as a zero-length bar. */
  assert.doesNotMatch(html,/National Day|>Promotion</);
});

test('V386 with no window the chart compares categories instead of periods',()=>{
  const {rowsFrom}=usageHarness(ENTRIES);
  const html=chart(rowsFrom(USAGE_NOW),null,null);
  assert.doesNotMatch(html,/is-was-v386/,'there is no previous period to draw');
  assert.match(html,/Times used, by category/);
});

test('V386 the chart states when there is nothing to draw rather than drawing nothing',()=>{
  const empty=chart([{category:'Referrals',uses:0,programmes:1}],null,null);
  assert.match(empty,/Nobody used a programme in this period/);
  /* Nothing measured at all is not "nobody used it" — it is not a chart. */
  assert.equal(chart([{category:'Promotion',uses:null,programmes:2}],null,null),'');
});

test('V386 the filter is scoped to this table, and asks for both dates or neither',()=>{
  const card=section('const growUsageFilterBarV386=','const growAnalyticsCardV375=');
  assert.match(card,/id="growUsageFromV386"/);
  assert.match(card,/id="growUsageToV386"/);
  /* The card above already carries a 30/60/90 filter, so this one says what it filters. */
  assert.match(card,/Showing every customer since you opened\. Set both dates to narrow this table\./);
  const wiring=section("const growUsageApplyV386=$('growUsageApplyV386');","const growTopicBack=");
  assert.match(wiring,/if\(!from\|\|!to\)return toast\(/,'a half-open window would have to invent an end');
  assert.match(wiring,/if\(from>to\)return toast\(/);
});

test('V386 the Overview table keeps its all-time figures — the filter was drawn on one table',()=>{
  const reads=section('const growUsageWindowedV386=','const snapshot=await growOverviewSnapshot');
  assert.match(reads,/business_programme_usage_v386/);
  /* The unbounded v271 read is still what feeds the Overview column, and the windowed pair is
     only fetched when a window is actually set. */
  assert.match(reads,/business_programme_usage_v271/);
  assert.match(reads,/growUsageWindowedV386\s*\)\s*\?Promise\.all\(\[|\(canRewards&&growUsageWindowedV386\)/);
});

test('V386 the migration windows every source on the event that made the customer a user',()=>{
  assert.equal(migration,canonical,'both copies of a migration must be byte-identical');
  for(const column of ['created_at','redemption.redeemed_at','grant_row.granted_at',
                       'redeemed_at','qualified_at','member.started_at'])
    assert.ok(migration.includes(`${column} >= v_from`),`${column} is not bounded by the window`);
  /* Singapore days, half-open, so "17 Aug" is the whole of the 17th here. */
  assert.match(migration,/\(p_to \+ 1\)::text \|\| ' 00:00:00\+08'/);
  /* A backwards window is refused rather than answered with a zero nobody asked for. */
  assert.match(migration,/the From date is after the To date/);
  /* v271 stays: a client running the previous deploy is still calling it. */
  assert.match(migration,/grant execute on function public\.business_programme_usage_v271\(uuid\) to authenticated/);
  assert.match(migration,/revoke all on function public\.business_programme_usage_v386\(uuid, date, date\) from public, anon/);
});

test('V386 the chart is plain DOM, because the CSP forbids a charting library',()=>{
  const helper=section('function growUsageComparisonChartV386(','const REPORT_SHARE_COLOURS_V297=');
  assert.doesNotMatch(helper,/<canvas|new Chart|import\(/);
  for(const rule of ['.grow-usage-chart-rows-v386','.grow-usage-chart-bar-v386','.grow-usage-filter-v386'])
    assert.ok(indexHtml.includes(rule),`${rule} has no styles`);
  /* Both series read from the one categorical palette, not from literals only this card knows. */
  assert.match(indexHtml,/\.grow-usage-chart-bar-v386\.is-now-v386[^}]*var\(--chart-1\)/);
});
