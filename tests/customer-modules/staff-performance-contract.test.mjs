import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing ${start}`);
  return app.slice(from,to);
}

test('Staff performance is hidden from roles without the finance capability',()=>{
  assert.match(app,/const FINANCE_MODULES=new Set\(\['expenses','pnl','staffperf'\]\)/);
  const settings=section('async function settingsPage(){','/* ---------- billing (read-only) ---------- */');
  assert.match(settings,/Expenses, P&amp;L and Staff performance require a finance-capable role/);
  assert.match(settings,/Expenses, P&amp;L and Staff performance were removed because/);
});

test('Staff performance uses Singapore calendar boundaries and an exclusive end instant',()=>{
  const list=section('async function staffPerfPage(drillId){','/* Drill-down: one staff member');
  const drill=section('async function staffPerfDrill(idParam){','/* ---------- daily report ---------- */');
  for(const source of [list,drill]){
    assert.match(source,/sgDateInputValue\(\)/);
    assert.match(source,/shiftSgDateInput\(/);
    assert.match(source,/sgDateBoundary\([^)]*\)/);
    assert.match(source,/toExclusive=sgDateBoundary\([^,]+,1\)/);
    assert.match(source,/\.gte\('occurred_at',from\)\.lt\('occurred_at',toExclusive\)/);
    assert.doesNotMatch(source,/toISOString\(\)\.slice\(0,10\)/);
    assert.doesNotMatch(source,/T23:59:59/);
  }
});
