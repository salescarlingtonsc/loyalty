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
  assert.match(settings,/Expenses, P&amp;L, Staff commission and Customer intelligence require a finance-capable role/);
  assert.match(settings,/Expenses, P&amp;L, Staff commission and Customer intelligence were removed because/);
});

test('Staff performance uses Singapore calendar boundaries and an exclusive end instant',()=>{
  /* nestly_v825: one page (the drill route preselects a team member on it), one RPC read whose
     window is the same Singapore-day pair every other report uses. */
  const list=section('async function staffPerfPage(drillId){','function enhanceStaffMembersTabsV164(');
  for(const source of [list]){
    assert.match(source,/sgDateInputValue\(\)/);
    assert.match(source,/sgDateBoundary\([^)]*\)/);
    assert.match(source,/toExclusive=sgDateBoundary\([^,]+,1\)/);
    assert.match(source,/p_from:from,p_to:toExclusive/);
    assert.doesNotMatch(source,/toISOString\(\)\.slice\(0,10\)/);
    assert.doesNotMatch(source,/T23:59:59/);
  }
});
