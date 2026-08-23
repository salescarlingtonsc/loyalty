/* nestly_v471 — the owner's eleventh annotated batch.
 *
 * PHOTO 4 (Rewards & Offer -> Overview, the "Times used, by category" chart). "Why point system
 * shows 26 while the rewards below do not tally with the sum of 26?" — asked once before and
 * answered by V470 with a verb on every row ('earned' vs 'redeemed'), which is true but was not
 * the answer wanted. Owner ruling 2026-08-23: "I don't need to know how many times customer
 * added points to the point system — remove Point system, don't need to track."
 *
 * PHOTO 3 (business profile -> social links). "Clicking this link in customer view should link to
 * the external app / website" — reported as landing on "a non-exist page IN the app".
 *
 * Both are EXECUTED here against the shipped helpers rather than grepped, because a source pin
 * cannot tell a chart that drops a row from a chart that never had one.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const appJs=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const section=(start,end,source=appJs)=>{
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing section ${start} … ${end}`);
  return source.slice(from,to);
};
const statement=(start,end,source=appJs)=>{
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing statement ${start} … ${end}`);
  return source.slice(from,to+end.length);
};
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const promotionDateShortV324=value=>value?String(value).split('-').reverse().join('/'):'';

/* ------------------------------------------------- photo 4: the engine leaves the chart ----- */

const rowsFrom=new Function('esc','entries','usage',`
  const growProgrammeEntriesV271=entries;
  const growOverviewChildRowV324=row=>row.type==='Reward';
  ${section('  const growAnalyticsCategoryV385=','  const growAnalyticsRowsV375=')}
  return growAnalyticsRowsFromUsageV386(usage);
`);
const chart=new Function('esc','promotionDateShortV324',`
  ${section('const GROW_USAGE_COMPARE_OPTIONS_V392=','function growUsageComparisonRangeV392(')}
  ${section('function growUsageComparisonChartV386(','const REPORT_SHARE_COLOURS_V297=')}
  return growUsageComparisonChartV386;
`)(esc,promotionDateShortV324);

/* The owner's own shape: an engine whose earn count dwarfs everything, two gifts under it, and a
   referral row that is a different event again. */
const ENTRIES=[
  {name:'Point system',type:'Point system',usageScopeV386:'point_system'},
  {name:'Free Lotion',type:'Reward',parent:'Point system',usageScopeV386:'reward',usageIdV386:'r1'},
  {name:'Free facial add-on',type:'Reward',parent:'Point system',usageScopeV386:'reward',usageIdV386:'r2'},
  {name:'Referrals',type:'Referrals',usageScopeV386:'referrals'}
];
const STAMPS_ENTRIES=[{name:'Stamp card',type:'Stamp card',usageScopeV386:'stamp_card'}].concat(ENTRIES.slice(1));
const USAGE={point_system:{customers:9,uses:26},stamp_card:{customers:9,uses:26},
  referrals:{customers:0,uses:0},
  rewards:[{reward_id:'r1',customers:5,uses:8},{reward_id:'r2',customers:2,uses:2}]};

const by=rows=>Object.fromEntries(rows.map(row=>[row.category,row]));

test('v471 the engine row carries no figure, but is still a real row with its gifts under it',()=>{
  const rows=by(rowsFrom(esc,ENTRIES,USAGE));
  assert.equal(rows['Point system'].uses,null,'26 earns is exactly the figure the owner asked to lose');
  assert.equal(rows['Point system'].untrackedV471,true);
  assert.equal(rows['Point system'].synthV413,undefined,'it is a real programme, not a synthesised header');
  assert.equal(rows['Point system'].childCountV413,2,'both gifts still hang off it');
  assert.equal(rows['Free Lotion'].uses,8,'the gifts are untouched — they are what this card measures');
  assert.equal(rows['Free facial add-on'].uses,2);
});

test('v471 a stamps firm gets the same treatment — the identical row, the identical bar',()=>{
  const rows=by(rowsFrom(esc,STAMPS_ENTRIES,USAGE));
  assert.equal(rows['Stamp card'].uses,null);
  assert.equal(rows['Stamp card'].untrackedV471,true);
});

test('v471 the chart drops the engine bar, so the gifts are scaled against each other',()=>{
  const rows=rowsFrom(esc,ENTRIES,USAGE);
  const figure=chart(rows,null,null);
  assert.ok(figure,'there are still measured rows, so there is still a chart');
  assert.doesNotMatch(figure,/Point system/,'the 26-tall bar is what flattened every gift beside it');
  assert.match(figure,/Free Lotion/);
  /* The peak is now the tallest MEASURED row (8), not 26 — so the 8 bar is full width. Against
     26 it was 30%, which is the whole complaint in one number. */
  assert.match(figure,/is-now-v386" style="width:100\.00%/);
});

test('v471 "not counted here" is not the same claim as "the server could not answer"',()=>{
  const markup=new Function('esc','rows','growUsageOpenGroupsV413',`
    const growAnalyticsRowsV375=rows;
    ${statement('const growUsageGroupKeyV413=',"||'group';")}
    const growCountCellV271=(value,verb)=>value==null
      ?'<span class="muted">Not tracked</span>'
      :esc(String(Number(value)))+(verb?' <span class="muted">'+esc(verb)+'</span>':'');
    const growOverviewChildRowV324=row=>row.type==='Reward';
    return ${statement('${growAnalyticsRowsV375.map(row=>{',"}).join('')").slice(2)};
  `)(esc,rowsFrom(esc,ENTRIES,USAGE),new Set());
  const engineRow=markup.split('</tr>').find(row=>row.includes('Point system'));
  assert.match(engineRow,/—/,'a dash says the column has nothing to say about this row');
  assert.doesNotMatch(engineRow,/Not tracked/,'that sentence means the read failed, which it did not');
  assert.match(engineRow,/Earning is not counted here/,'and a screen reader is told why');
  const giftRow=markup.split('</tr>').find(row=>row.includes('Free Lotion'));
  assert.match(giftRow,/redeemed/,'the gifts keep their V470 verb');
});

/* ------------------------------------------------- photo 1: a collected slot wears a crown -- */

const heroCard=new Function('esc','ct','CUI',`
  ${statement('const HERO_STAMP_COMPACT_FROM_V422=','\n}')}
  return customerHeroStampCardV422;
`)(esc,()=>'progress',{icon:()=>'<svg data-gift></svg>'});

test('v471 a collected stamp is marked with a crown, an empty one still shows its number',()=>{
  const markup=heroCard({slots:6,shown:2,carried:0,
    milestones:[{slot:4,name:'Kaya Butter Supreme',claimed:false}],
    next:{name:'Kaya Butter Supreme'}});
  const cells=markup.split('data-hero-stamp-slot-v422=').slice(1);
  assert.equal(cells.length,6,'every slot on the card is drawn');
  /* The crown is the SOLID path, not CUI.icon('crown') — a 24px stroked glyph blurs to a blob
     inside a 26px circle, and smaller still in the compact variant. */
  const crown=/M2 5\.4l3\.1 2\.2L8 3l2\.9 4\.6L14 5\.4l-1 7\.6H3L2 5\.4Z/;
  assert.match(cells[0],crown,'stamp 1 was collected, so it wears a crown');
  assert.match(cells[1],crown);
  assert.doesNotMatch(cells[2],crown,'stamp 3 is not collected yet');
  assert.match(cells[2],/customer-hero-stamp-num-v422">3</,'an empty slot still says which slot it is');
  assert.doesNotMatch(markup,/M8 1\.6l1\.9 4/,'the v422 star is gone from every cell');
});

test('v471 the crown survives the compact (long card) variant unchanged',()=>{
  const markup=heroCard({slots:40,shown:1,carried:0,milestones:[],next:null});
  assert.match(markup,/is-compact-v422/,'a 40-slot card is drawn compact');
  assert.match(markup,/M2 5\.4l3\.1 2\.2L8 3l2\.9 4\.6L14 5\.4l-1 7\.6H3L2 5\.4Z/,
    'the crown is one path at one size — the cell shrinks, the mark does not change');
});

/* ------------------------------------------------- photo 3: links leave the app ------------- */

test('v471 a business link is opened through the native bridge, not left to the app window',async()=>{
  const wire=new Function('globalThis_',`
    const globalThis=globalThis_;
    ${statement('function wireCustomerBusinessLinksV471(','\n}')}
    return wireCustomerBusinessLinksV471;
  `);
  const opened=[];
  const listeners=[];
  const link={
    dataset:{},
    getAttribute:name=>name==='href'?'https://www.example.com':null,
    addEventListener:(type,handler)=>listeners.push({type,handler})
  };
  const root={querySelectorAll:selector=>{
    assert.equal(selector,'.customer-business-link-v418');
    return [link];
  }};
  const fakeGlobal={NestlyNativeBridge:{openExternal(url){opened.push(url);return Promise.resolve(true)}},
    open:()=>assert.fail('a plain window.open would stay inside the installed app on a same-origin link')};
  wire(fakeGlobal)(root);
  assert.equal(listeners.length,1,'the anchor is upgraded exactly once');
  let prevented=false;
  listeners[0].handler({button:0,defaultPrevented:false,preventDefault(){prevented=true}});
  await Promise.resolve();
  assert.equal(prevented,true,'the in-window navigation is what has to be stopped');
  assert.deepEqual(opened,['https://www.example.com']);
});

test('v471 a modified click is left alone, and a second wiring pass does not double-bind',()=>{
  const wire=new Function('globalThis_',`
    const globalThis=globalThis_;
    ${statement('function wireCustomerBusinessLinksV471(','\n}')}
    return wireCustomerBusinessLinksV471;
  `);
  const listeners=[];
  const link={dataset:{},getAttribute:()=>'https://www.example.com',
    addEventListener:(type,handler)=>listeners.push(handler)};
  const root={querySelectorAll:()=>[link]};
  const wired=wire({NestlyNativeBridge:{openExternal:()=>assert.fail('cmd-click must still open a tab')}});
  wired(root);
  wired(root);
  assert.equal(listeners.length,1,'re-wiring the same node must not stack handlers');
  let prevented=false;
  listeners[0]({button:0,metaKey:true,defaultPrevented:false,preventDefault(){prevented=true}});
  assert.equal(prevented,false,'the customer asked for a new tab; give them one');
});

test('v471 the anchor keeps working with no bridge and no script',()=>{
  const markup=section('function customerBusinessGalleryMarkupV418(','function customerBusinessTaglineV385(');
  assert.match(markup,/class="customer-business-link-v418" href="\$\{esc\(item\.url\)\}" target="_blank" rel="noopener noreferrer"/,
    'the upgrade must not replace the href — a broken bundle still has to leave a usable link');
  assert.match(appJs,/wireCustomerBusinessLinksV471\(root\|\|document\)/,
    'and it must be wired wherever the gallery is');
});
