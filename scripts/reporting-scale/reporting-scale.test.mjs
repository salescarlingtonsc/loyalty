import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../../',import.meta.url);
const app=await readFile(new URL('app/index.html',root),'utf8');
const migration=await readFile(new URL('db/migrations/20260718135940_frenly_v18_scalable_reporting.sql',root),'utf8');
const permissionSources=(await Promise.all([
  'db/migrations/20260717_frenly_v10_1_policy_snapshot.sql',
  'db/migrations/20260718_frenly_v14_rls_billing_modules_till.note.md',
  'db/migrations/20260718_frenly_v17_branch_visibility.sql'
].map(path=>readFile(new URL(path,root),'utf8')))).join('\n');

function appSection(from,to){
  const start=app.indexOf(from);
  const end=app.indexOf(to,start);
  assert.notEqual(start,-1,`missing app section: ${from}`);
  assert.notEqual(end,-1,`missing app section terminator: ${to}`);
  return app.slice(start,end);
}

function sqlFunction(name){
  const start=migration.indexOf(`create or replace function public.${name}`);
  const end=migration.indexOf('\n$$;',start);
  assert.notEqual(start,-1,`missing SQL function: ${name}`);
  assert.notEqual(end,-1,`unterminated SQL function: ${name}`);
  return migration.slice(start,end+4);
}

function loadReportingHelpers(){
  const match=app.match(/\/\* reporting-scale:start[\s\S]*?\/\* reporting-scale:end \*\//);
  assert.ok(match,'reporting helper marker is missing');
  const context={};
  vm.runInNewContext(`${match[0]};globalThis.helpers={fetchAllRows,sgDateBoundary};`,context);
  return context.helpers;
}

test('fetchAllRows returns every row beyond the 1,000-row API cap',async()=>{
  const {fetchAllRows}=loadReportingHelpers();
  const source=Array.from({length:2505},(_,id)=>({id}));
  const calls=[];
  const result=await fetchAllRows(()=>({
    range:async(from,to)=>{calls.push([from,to]);return {data:source.slice(from,to+1),error:null}}
  }),1000);

  assert.equal(result.length,2505);
  assert.equal(JSON.stringify(result.map(x=>x.id)),JSON.stringify(source.map(x=>x.id)));
  assert.equal(JSON.stringify(calls),JSON.stringify([[0,999],[1000,1999],[2000,2999]]));
});

test('fetchAllRows checks the page after an exact multiple and propagates errors',async()=>{
  const {fetchAllRows}=loadReportingHelpers();
  const source=Array.from({length:2000},(_,id)=>({id}));
  let calls=0;
  const result=await fetchAllRows(()=>({
    range:async(from,to)=>{calls++;return {data:source.slice(from,to+1),error:null}}
  }),1000);
  assert.equal(result.length,2000);
  assert.equal(calls,3);

  await assert.rejects(
    fetchAllRows(()=>({range:async()=>({data:null,error:new Error('page failed')})})),
    /page failed/
  );
});

test('fetchAllRows remains complete when the server cap is below the requested page size',async()=>{
  const {fetchAllRows}=loadReportingHelpers();
  const source=Array.from({length:2505},(_,id)=>({id}));
  const calls=[];
  const result=await fetchAllRows(()=>({
    range:async(from,to)=>{
      calls.push([from,to]);
      return {data:source.slice(from,Math.min(to+1,from+500)),error:null,count:source.length};
    }
  }),1000);

  assert.equal(result.length,2505);
  assert.equal(calls.length,6);
  assert.equal(JSON.stringify(result.map(x=>x.id)),JSON.stringify(source.map(x=>x.id)));
});

test('Singapore-local day bounds keep 23:30 in-day and midnight in the next day',()=>{
  const {sgDateBoundary}=loadReportingHelpers();
  const start=sgDateBoundary('2026-07-18');
  const end=sgDateBoundary('2026-07-18',1);
  assert.equal(start,'2026-07-17T16:00:00.000Z');
  assert.equal(end,'2026-07-18T16:00:00.000Z');

  const at2330=Date.parse('2026-07-18T15:30:00.000Z');
  const atMidnight=Date.parse('2026-07-18T16:00:00.000Z');
  assert.ok(at2330>=Date.parse(start)&&at2330<Date.parse(end));
  assert.equal(atMidnight<Date.parse(end),false);
  const sgBucket=iso=>new Date(Date.parse(iso)+8*3600000).toISOString().slice(0,10);
  assert.equal(sgBucket('2026-07-18T15:30:00.000Z'),'2026-07-18');
  assert.equal(sgBucket('2026-07-18T16:00:00.000Z'),'2026-07-19');

  assert.doesNotMatch(migration,/p_(?:from|to)::timestamptz/i);
  assert.match(migration,/p_from::timestamp at time zone 'Asia\/Singapore'/i);
  assert.match(migration,/\(p_to \+ 1\)::timestamp at time zone 'Asia\/Singapore'/i);
  assert.match(migration,/\(s\.occurred_at at time zone 'Asia\/Singapore'\)::date as sale_day/i);
  assert.match(migration,/extract\(isodow from s\.occurred_at at time zone 'Asia\/Singapore'\)/i);
});

test('authorization helper signatures and grants match applied v17 definitions',()=>{
  assert.match(permissionSources,/function app\.has_perm\(p_business uuid, p_perm text\)/i);
  assert.match(permissionSources,/app\.can_module\(business, module\)/i);
  assert.match(permissionSources,/function app\.can_see_branch\(p_business uuid, p_branch uuid\)/i);
  assert.match(permissionSources,/grant execute on function app\.can_see_branch\(uuid,uuid\) to authenticated/i);
  assert.doesNotMatch(migration,/\bapp\.can_module_read\s*\(/i);
  assert.doesNotMatch(migration,/function app\.can_module_read\b/i);
  for(const signature of ['has_perm\\(uuid, text\\)','can_module\\(uuid, text\\)','can_see_branch\\(uuid, uuid\\)']){
    assert.match(migration,new RegExp(`revoke execute on function app\\.${signature} from public, anon`,'i'));
    assert.match(migration,new RegExp(`grant execute on function app\\.${signature} to authenticated`,'i'));
  }
});

test('dashboard and report RPCs retain RLS and deny foreign tenant or branch scopes',()=>{
  for(const name of ['get_dashboard_summary','get_reports_summary']){
    const fn=sqlFunction(name);
    assert.match(fn,/security invoker/i);
    assert.match(fn,/auth\.uid\(\) is null/i);
    assert.match(fn,/app\.has_perm\(p_business, 'view_sales'\)/i);
    if(name==='get_reports_summary'){
      assert.match(fn,/app\.can_module\(p_business, 'reports'\)/i);
    }
    assert.match(fn,/b\.id = p_branch and b\.business_id = p_business/i);
    assert.match(fn,/not app\.can_see_branch\(p_business, p_branch\)/i);
    assert.match(fn,/errcode = '42501'/i);
  }
  assert.match(migration,/revoke all on function public\.get_dashboard_summary[\s\S]*?from public, anon/i);
  assert.match(migration,/revoke all on function public\.get_reports_summary[\s\S]*?from public, anon/i);
  assert.match(migration,/grant execute on function public\.get_dashboard_summary[\s\S]*?to authenticated/i);
  assert.match(migration,/grant execute on function public\.get_reports_summary[\s\S]*?to authenticated/i);
});

test('reporting semantics are aggregated on immutable snapshots and current liabilities',()=>{
  const dashboard=sqlFunction('get_dashboard_summary');
  const reports=sqlFunction('get_reports_summary');
  assert.match(dashboard,/counts_as_visit/i);
  assert.match(dashboard,/counts_as_revenue/i);
  assert.match(dashboard,/entry_type = 'earn'/i);
  assert.match(dashboard,/greatest\(cb\.balance_cents, 0\)/i);
  assert.match(reports,/counts_as_revenue/i);
  assert.match(reports,/points_ledger/i);
  assert.match(reports,/gift_cards/i);
  assert.match(reports,/memberships/i);
});

test('SPA uses aggregates, bounded customer pages, and paged sales export',()=>{
  const dashboard=appSection('async function dashboard()','/* ---------- customers ---------- */');
  const clients=appSection('async function clientsPage()','async function clientDetail');
  const reports=appSection('async function reportsPage()','/* ---------- get started');

  assert.match(dashboard,/sb\.rpc\('get_dashboard_summary'/);
  assert.doesNotMatch(dashboard,/\.from\('sales'\)/);
  assert.match(clients,/\.range\(from,from\+CLIENT_PAGE_SIZE-1\)/);
  assert.match(clients,/\.in\('client_id',ids\)/);
  assert.match(clients,/fetchAllRows/);
  assert.match(reports,/sb\.rpc\('get_reports_summary'/);
  assert.match(reports,/lastSales=await fetchAllRows/);
  assert.match(reports,/\.order\('occurred_at'\)\.order\('id'\)/);
});
