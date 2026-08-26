import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

/* nestly_v519 — the Dashboard KPI drill-downs must be filtered by the SAME branch set the tile
   was counted with.

   Measured on production 2026-08-26, before this fix: with the top-bar scope set to Cubbly's
   "Kopitiam 2" branch (a real branch with zero sales), the Valid visits tile correctly read 0 and
   the Revenue tile correctly read SGD 0.00 — and clicking either one opened a dialog listing the
   WHOLE business: 46 visit rows, and 56 revenue rows totalling SGD 4,485.00. The tiles come from
   get_dashboard_summary_v155, which filters `s.branch_id = any(v_scope_ids)`; the dialog ran its
   own `sales` select filtered only by business_id and the date range.

   These tests EXECUTE the query-building closure out of app.js against a recording stub, rather
   than grepping for the line — a source regex would have matched happily before the fix too, and
   the repo has been burned by exactly that (see the V405/V406/V407 stack, where three defects hid
   behind assertions that only proved a string existed). */

const here=path.dirname(fileURLToPath(import.meta.url));
const repo=path.resolve(here,'../..');
const app=fs.readFileSync(path.join(repo,'app/app.js'),'utf8');

/* Extract the real closure from source: from the `fetchAllRowsResult(` call that opens the
   drill-down's sales read, to the `});` that closes it. Extracting the BLOCK (not a variable)
   keeps the test pinned to the code that actually runs. */
function drillQuerySource(){
  const marker="const {data,error}=await fetchAllRowsResult(()=>{";
  const from=app.indexOf(marker);
  assert.notEqual(from,-1,'missing the drill-down sales read — did the query stop being a closure?');
  const open=app.indexOf('{',app.indexOf('()=>',from));
  let depth=0;
  for(let i=open;i<app.length;i+=1){
    if(app[i]==='{')depth+=1;
    else if(app[i]==='}'){
      depth-=1;
      if(depth===0)return app.slice(open+1,i);
    }
  }
  throw new Error('unbalanced braces in the drill-down sales read');
}

/* A chainable PostgREST-shaped stub that records every filter it is given. */
function makeStub(){
  const calls=[];
  const builder=new Proxy({},{
    get(_target,prop){
      if(prop==='then')return undefined;
      return (...args)=>{calls.push({method:String(prop),args});return builder};
    }
  });
  return {calls,sb:{from(table){calls.push({method:'from',args:[table]});return builder}}};
}

function runDrillQuery(branchIdsV519){
  const {calls,sb}=makeStub();
  const body=drillQuerySource();
  const fn=new Function('sb','S','branchIdsV519','sgDateBoundary','from','to',body);
  fn(sb,{biz:{id:'biz-1'}},branchIdsV519,
    (day,offset=0)=>`${day}#${offset}`,'2026-07-28','2026-08-26');
  return calls;
}

const branchFilter=calls=>calls.find(call=>call.method==='in'&&call.args[0]==='branch_id');

test('V519 the drill-down sales read is filtered by the resolved reporting branch ids',()=>{
  const ids=['9a9081fb-fb48-49c7-a1c7-2bfb3d3ec263','45a463f4-5d91-4115-9fe9-f9da056cd369'];
  const filter=branchFilter(runDrillQuery(ids));
  assert.ok(filter,'the dialog read every branch — a scoped tile would open an unscoped list');
  assert.deepEqual(filter.args[1],ids,'the dialog must use the SAME ids the server counted');
});

test('V519 a single-branch scope narrows the dialog to that one branch',()=>{
  const filter=branchFilter(runDrillQuery(['45a463f4-5d91-4115-9fe9-f9da056cd369']));
  assert.ok(filter,'a single-branch scope must still reach the query');
  assert.deepEqual(filter.args[1],['45a463f4-5d91-4115-9fe9-f9da056cd369']);
});

test('V519 with no resolved scope the read stays business-wide',()=>{
  /* The Daily report supplies its own already-scoped rows and never reaches this path, so a null
     list must not degrade into `in('branch_id',[])`, which would match nothing. */
  assert.equal(branchFilter(runDrillQuery(null)),undefined);
  assert.equal(branchFilter(runDrillQuery([])),undefined);
});

test('V519 the branch filter never replaces the business or period predicates',()=>{
  const calls=runDrillQuery(['branch-a']);
  assert.ok(calls.some(call=>call.method==='eq'&&call.args[0]==='business_id'),'lost the tenant filter');
  assert.ok(calls.some(call=>call.method==='gte'&&call.args[0]==='occurred_at'),'lost the period start');
  assert.ok(calls.some(call=>call.method==='lt'&&call.args[0]==='occurred_at'),'lost the period end');
});

test('V519 the call site hands down the branch ids the server reported, not a second derivation',()=>{
  /* The whole class of bug is a SECOND client-side answer to "which branches am I looking at".
     The ids must come from the summary payload's own scope block. */
  assert.match(app,/branchIdsV519:Array\.isArray\(d\?\.scope\?\.branch_ids\)\?d\.scope\.branch_ids:null/);
});
