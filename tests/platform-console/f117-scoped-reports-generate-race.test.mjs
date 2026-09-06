/* Audit finding F117 — renderScopedReports's `generate()` closure (the
 * admin/sales_staff Reports page) writes its result straight into the
 * shared #platformScopedReportResult host with no token/generation guard.
 * Selecting a different firm and clicking "Generate report" again before the
 * first request resolves fires a second overlapping generate() call against
 * the same host; if the FIRST (now superseded) firm's three-RPC round trip
 * resolves after the second, its brief silently overwrites the correct one
 * while the radio button and URL still show the newly selected firm — a
 * wrong-business data display for the operator.
 *
 * This loads the REAL platform-console.js in a vm sandbox (no jsdom in this
 * repo), drives it through the actual render() dispatcher into the real
 * renderScopedReports (reached via the admin/sales_staff scoped path), then
 * fires the real captured form onsubmit handler twice with controllable
 * (deferred) RPC promises for two different firms, exactly reproducing the
 * "select firm A, submit, select firm B, submit before A resolves" sequence.
 */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect,console};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

function stubCUI(){
  return {
    icon:name=>`<i>${name}</i>`,
    pageHeader:({title})=>`<h1>${title||''}</h1>`,
    card:({title,body})=>`<section>${title||''}${body||''}</section>`,
    table:({rows})=>`<table>${(rows||[]).length}</table>`,
    emptyState:({title})=>`<div data-empty>${title||''}</div>`,
    errorState:({title,message})=>`<div class="err">${title||''}:${message||''}</div>`,
    loadingState:({title})=>`<div class="loading">${title||''}</div>`,
    field:()=>'<div data-field></div>',
    status:text=>`<span>${text}</span>`,
    focusRoute:()=>{},
    announce:()=>{}
  };
}

// A registry-backed fake element: querySelector(selector) always returns the
// SAME object for the same selector string, so a handler attached by the
// real code (e.g. `main.querySelector('#platformScopedReportForm').onsubmit=
// ...`) can be retrieved and invoked directly by the test, and writes to
// `#platformScopedReportResult` from two overlapping calls land on one
// shared object exactly as they would on one shared DOM node.
function makeContainer(){
  const registry=new Map();
  const get=selector=>{
    if(!registry.has(selector)){
      const el={
        value:'',disabled:false,onclick:null,onsubmit:null,onchange:null,_html:'',
        isConnected:true,
        querySelector:()=>null,querySelectorAll:()=>[],
        addEventListener(){},setAttribute(){},getAttribute:()=>null
      };
      Object.defineProperty(el,'innerHTML',{get(){return el._html},set(v){el._html=v}});
      registry.set(selector,el);
    }
    return registry.get(selector);
  };
  const container={_html:'',isConnected:true,querySelector:get,querySelectorAll:()=>[]};
  Object.defineProperty(container,'innerHTML',{
    get(){return container._html},set(v){container._html=v}
  });
  return container;
}

function deferred(){
  let resolve;
  const promise=new Promise(res=>{resolve=res});
  return {promise,resolve};
}

test('two overlapping "Generate report" submissions for different firms cannot let the stale firm win the shared result host',async()=>{
  const Console=await loadConsole();
  const main=makeContainer();
  const root=makeContainer();
  root.querySelector=selector=>selector==='#platformMain'?main:null;

  const access={role:'admin',module_perms:{'*':'rw'},scope:'own_created_or_assigned'};
  const gates={'firm-a':deferred(),'firm-b':deferred()};
  const started={'firm-a':deferred(),'firm-b':deferred()};

  const sb={
    rpc:async(name,args={})=>{
      if(name==='get_workspace_locale_preference_v97')return {data:{locale:'en',version:1},error:null};
      if(name==='platform_list_my_access_v89')return {data:access,error:null};
      if(name==='platform_list_my_firms_v105'){
        return {data:{items:[],total_count:0,next_cursor:{},snapshot_at:null},error:null};
      }
      if([
        'platform_get_assigned_firm_report_v94',
        'platform_get_catalogue_affinity_v94',
        'platform_get_consultative_recommendations_v94'
      ].includes(name)){
        const biz=args.p_business;
        started[biz].resolve();
        await gates[biz].promise;
        if(name==='platform_get_assigned_firm_report_v94'){
          return {data:{kpis:{active_customers:biz==='firm-a'?111:222}},error:null};
        }
        return {data:{},error:null};
      }
      throw new Error(`unexpected rpc ${name}`);
    }
  };

  const CUI=stubCUI();
  await Console.render({
    root,sb,CUI,brand:{},hash:'#/platform/reports',
    isCurrent:()=>true,onSignOut:()=>{},workspaceHash:'#/'
  });

  const form=main.querySelector('#platformScopedReportForm');
  assert.equal(typeof form.onsubmit,'function','the real onsubmit handler must have been attached');
  main.querySelector('#platformScopedReportFrom').value='2026-08-01';
  main.querySelector('#platformScopedReportTo').value='2026-08-31';
  const fakeEvent=firmId=>({preventDefault(){},currentTarget:{querySelector:()=>({value:firmId})}});

  // Select firm A and submit.
  const submitA=form.onsubmit(fakeEvent('firm-a'));
  await started['firm-a'].promise;
  // Before A resolves, select firm B and submit again — the exact scenario
  // in the finding: switch firms, re-click Generate before the first finishes.
  const submitB=form.onsubmit(fakeEvent('firm-b'));
  await started['firm-b'].promise;

  // B (the CURRENTLY selected, newer request) resolves first.
  gates['firm-b'].resolve();
  await submitB;
  const host=main.querySelector('#platformScopedReportResult');
  assert.ok(host.innerHTML.includes('222'),'firm B\'s brief must be on screen once it resolves');
  assert.ok(!host.innerHTML.includes('111'),'firm A\'s stale brief must not be shown yet');

  // A (the superseded, OLDER request) resolves late.
  gates['firm-a'].resolve();
  await submitA;

  assert.ok(host.innerHTML.includes('222'),
    'firm B\'s brief must still be on screen after the stale firm A request finally resolves');
  assert.ok(!host.innerHTML.includes('111'),
    'a late-resolving stale firm A response must never overwrite the currently selected firm B\'s brief');
});
