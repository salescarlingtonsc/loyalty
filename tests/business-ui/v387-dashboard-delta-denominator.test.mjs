import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

/* V387 — the owner's second pass on photo 1 of the 2026-08-17 review.
 *
 * V385 answered "which period is this compared against" and shipped it as a legend under the
 * KPI row. The owner ringed the same chip again: "the 400% still unknown". The question a
 * percentage raises is not which window — it is 400% of WHAT — and the only answer is the
 * previous period's own figure. These assertions execute the shipped helpers against the exact
 * numbers on the owner's dashboard.
 */

const appJs=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const indexHtml=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');
const statement=(start,end)=>{
  const from=appJs.indexOf(start),to=appJs.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing statement ${start}`);
  return appJs.slice(from,to+end.length);
};
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const promotionDateShortV324=value=>value?String(value).split('-').reverse().join('/'):'';

const dash=new Function('esc','promotionDateShortV324',`
  ${statement('const shiftSgDateInput=(date,days)=>{','\n};')}
  ${statement('function daysBetweenSgInputsV153(','\n}')}
  ${statement('function previousEquivalentRangeV153(','\n}')}
  ${statement('function percentageChangeV153(','\n}')}
  ${statement('function dashboardMetricWasLineV387(','\n}')}
  ${statement('function dashboardDeltaLegendV385(','\n}')}
  return {was:dashboardMetricWasLineV387,legend:dashboardDeltaLegendV385,
          pct:percentageChangeV153,prev:previousEquivalentRangeV153};
`)(esc,promotionDateShortV324);

/* The owner's own dashboard: 20/07/2026 – 18/08/2026 selected, 5 new members, chip reads 400%. */
const RANGE=dash.prev('2026-07-20','2026-08-18');

test('V387 the chip on the owner\'s screen is 5 against a previous 1, and the tile says so',()=>{
  assert.deepEqual([RANGE.previousFrom,RANGE.previousTo,RANGE.days],['2026-06-20','2026-07-19',30]);
  const delta=dash.pct(5,1);
  assert.equal(delta,400,'the reproduction must be the figure the owner photographed');
  const html=dash.was({key:'new',value:'5',delta,was:'1'},RANGE);
  assert.match(html,/was 1/,'the percentage must carry the number it is a percentage of');
});

test('V387 the previous figure is formatted like the tile it sits under',()=>{
  /* Revenue is money on both lines; a bare cents integer under "SGD 2,397.30" is not a
     comparison a reader can make. */
  assert.match(dash.was({key:'revenue',value:'SGD 2397.30',delta:20,was:'SGD 2000.00'},RANGE),/was SGD 2000\.00/);
  assert.match(dash.was({key:'visits',value:'26',delta:30,was:'20'},RANGE),/was 20/);
});

test('V387 a tile with no comparison states nothing rather than inventing a zero',()=>{
  /* Inactive customers carries no delta at all. */
  assert.equal(dash.was({key:'inactive',value:'0',was:null},RANGE),'');
  /* A first-ever period: percentageChangeV153 returns null when the previous figure is 0, and a
     "was 0" would invite the reading that the business grew from nothing when in truth nobody
     was measured. */
  assert.equal(dash.pct(5,0),null);
  assert.equal(dash.was({key:'new',value:'5',delta:dash.pct(5,0),was:null},RANGE),'');
});

test('V387 the period is stated once, not once per tile',()=>{
  /* Three tiles each repeating "20/06/2026 – 19/07/2026" is three readings of one fact — the
     duplication V200 deleted a whole headline for. The tile carries the number; the legend
     under the row carries the window. */
  const tile=dash.was({key:'new',value:'5',delta:400,was:'1'},RANGE);
  assert.doesNotMatch(tile,/20\/06\/2026|19\/07\/2026/);
  const legend=dash.legend([{delta:400,was:'1'}],RANGE);
  assert.match(legend,/20\/06\/2026 – 19\/07\/2026/);
  assert.match(legend,/previous 30 days/);
  /* And the legend names the word the tiles use, so the two read as one sentence. */
  assert.match(legend,/"was"/);
});

test('V387 the legend stays absent when no tile has a comparison to make',()=>{
  assert.equal(dash.legend([{delta:null,was:null}],RANGE),'');
});

test('V387 the previous figure is styled as secondary, under the value',()=>{
  assert.match(indexHtml,/\.metric-was-v387\{[^}]*display:block[^}]*color:var\(--muted\)/);
  /* It is rendered inside the tile, between the value row and the action label. */
  const row=statement('kpis.innerHTML=metrics.map(','.join(\'\')+dashboardDeltaLegendV385(metrics,previousRange);');
  assert.ok(row.indexOf('dashboardMetricWasLineV387(metric,previousRange)')>row.indexOf('metric-value-row'),
    'the previous figure must follow the figure it is compared with');
});
