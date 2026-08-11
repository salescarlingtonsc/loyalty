import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
}

test('Record sale page header carries a View sales history button next to Scan customer QR, styled the same way', ()=>{
  const drawStep1=section('function drawStep1(){','const inp=$(\'tPhone\');');
  // Both actions are built with CUI.action(...) using the ghost/secondary variant pattern.
  assert.match(drawStep1,/CUI\.action\(\{id:'tScanRedemption',label:'Scan customer QR',iconName:'scan',variant:'secondary'\}\)/);
  assert.match(drawStep1,/CUI\.action\(\{id:'tViewSalesHistoryV253',label:'View sales history',iconName:'sales',variant:'secondary'\}\)/);
});

test('View sales history targets the existing #/sales ledger route via the nav() helper', ()=>{
  const wiring=section("$('tFind').onclick=doFind;",'document.querySelectorAll(\'[data-k]\')');
  assert.match(wiring,/\$\('tViewSalesHistoryV253'\)\.onclick=\(\)=>nav\('#\/sales'\)/);
  // '#/sales' resolves to salesPage(), the existing historical sales ledger — not a new page.
  const routeMap=section('const P={dashboard,till:tillPage','};\n  const pageFn');
  assert.match(routeMap,/sales:salesPage/);
});

test("the button's visibility gate matches the destination route's own access guard (canReadModule('sales'))", ()=>{
  const drawStep1=section('function drawStep1(){','const inp=$(\'tPhone\');');
  const wiring=section("$('tFind').onclick=doFind;",'document.querySelectorAll(\'[data-k]\')');
  // Header only renders the action when the same expression the /sales route guard uses is true.
  assert.match(drawStep1,/canReadModule\('sales'\)\?CUI\.action\(\{id:'tViewSalesHistoryV253'/);
  // The click handler is wired under the identical guard, so a hidden button can never fire.
  assert.match(wiring,/if\(canReadModule\('sales'\)&&\$\('tViewSalesHistoryV253'\)\)/);
  // The route guard that protects a typed #/sales hash reduces to canReadModule(pageKey) for
  // any ordinary (non owner-only) module — 'sales' is one, so this is the same condition.
  /* V275 inserted one exemption line between these two: the bar-only bottle surfaces answer with
     their own "not available for this business type" card instead of bouncing to the dashboard.
     'sales' is not one of them, so the condition this test cares about is byte-for-byte the same
     for the /sales route. */
  assert.match(app,/if\(MODULES\[pageKey\]&&!OWNER_ONLY_MODULES\.has\(pageKey\)&&pageKey!=='dashboard'\s*\n(?:\s*&&!BOTTLE_SURFACES_V275\.has\(pageKey\)\s*\n)?\s*&&!canReadModule\(pageKey\)\)\{/);
  assert.ok(!app.includes("OWNER_ONLY_MODULES=new Set(['branches','staffmembers','settings','setup','sales'"),
    'sales must not be owner-only, or the route guard and this button\'s gate would diverge');
});
