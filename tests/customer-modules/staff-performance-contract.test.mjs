import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing ${start}`);
  return app.slice(from,to);
}

test('Staff performance is hidden from roles without the finance capability',()=>{
  /* nestly_v522: this pinned the exact membership literal, so adding a fourth finance module
     failed it for the wrong reason. What the test is actually about is that staffperf is
     finance-gated, so it asserts membership and leaves the set free to grow. */
  const financeSet=app.match(/const FINANCE_MODULES=new Set\(\[([^\]]*)\]\)/);
  assert.ok(financeSet,'FINANCE_MODULES is no longer a Set literal');
  const members=financeSet[1].split(',').map(entry=>entry.trim().replace(/^'|'$/g,''));
  for(const required of ['expenses','pnl','staffperf'])assert.ok(members.includes(required),
    `${required} must stay finance-gated`);
  const settings=section('async function settingsPage(){','/* ---------- billing (read-only) ---------- */');
  /* The copy has to name every module the role actually loses, or it under-reports the change. */
  assert.match(settings,/Expenses, P&amp;L, Staff performance and Customer intelligence require a finance-capable role/);
  assert.match(settings,/Expenses, P&amp;L, Staff performance and Customer intelligence were removed because/);
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
