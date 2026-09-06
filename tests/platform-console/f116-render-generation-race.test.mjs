/* Audit finding F116 — app/platform-console.js's render() bumps `renderGeneration`
 * and checks it once, right after loadPlatformLocale(sb). It then awaits the
 * platform_list_my_access_v89 RPC and, in every branch after that await
 * (the catch's denied/load-failure paths, the `!access` guard, and the
 * success path that builds shellHtml), wrote directly to root.innerHTML with
 * no re-check of generation/isCurrent — the one spot in this file that
 * omitted the guard every other render task in it applies after its own
 * awaits.
 *
 * This loads the REAL platform-console.js in a vm sandbox (no jsdom in this
 * repo) and drives two overlapping render() calls with controllable
 * (deferred) RPC promises. Render call A is let run until it is genuinely
 * suspended INSIDE its own access RPC (mirroring the real race — an
 * in-flight platform_list_my_access_v89 round trip); only then does render
 * call B start, run to completion and paint root. A's access RPC is then
 * resolved late. Before the fix, A's completion clobbered B's page with no
 * error; the fix makes it a silent no-op.
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

function stubElement(){
  const el={
    _html:'',
    isConnected:true,
    querySelector:()=>null,
    querySelectorAll:()=>[]
  };
  Object.defineProperty(el,'innerHTML',{
    get(){return el._html},
    set(value){el._html=value}
  });
  return el;
}

function deferred(){
  let resolve;
  const promise=new Promise(res=>{resolve=res});
  return {promise,resolve};
}

test('a stale render() generation whose access RPC resolves late does not overwrite a newer, already-painted page',async()=>{
  const Console=await loadConsole();
  const main=stubElement();
  const root=stubElement();
  root.querySelector=selector=>selector==='#platformMain'?main:null;

  const access={role:'super_admin',module_perms:{},scope:'all'};
  // Two independent, per-call-slot deferred pairs: [0] is render call A's
  // (the stale one), [1] is render call B's (the fresh one). `started[n]`
  // resolves the instant that call's access RPC begins (before it awaits),
  // so the test can wait for A to be genuinely suspended inside the RPC
  // before starting B, instead of guessing a number of microtask ticks.
  const started=[deferred(),deferred()];
  const resolved=[deferred(),deferred()];
  let accessCallIndex=0;

  const sb={
    rpc:async(name)=>{
      if(name==='get_workspace_locale_preference_v97'){
        return {data:{locale:'en',version:1},error:null};
      }
      if(name==='platform_list_my_access_v89'){
        const idx=accessCallIndex++;
        started[idx].resolve();
        const data=await resolved[idx].promise;
        return {data,error:null};
      }
      if(name==='platform_list_support_tickets_v672'){
        return {data:{tickets:[],open_count:0,has_more:false},error:null};
      }
      throw new Error(`unexpected rpc ${name}`);
    }
  };

  const CUI=stubCUI();
  const baseArgs={
    root,sb,CUI,brand:{},hash:'#/platform/support',
    isCurrent:()=>true,onSignOut:()=>{}
  };
  // A distinguishing, content-visible marker per call (embedded verbatim into
  // shellHtml's "Back to workspace" href) so an overwrite is DETECTABLE —
  // same-hash/same-access renders would otherwise produce byte-identical
  // output and the assertion could pass even if B's page got clobbered.
  const argsA={...baseArgs,workspaceHash:'#/from-stale-a'};
  const argsB={...baseArgs,workspaceHash:'#/from-fresh-b'};

  // Kick off the stale render (generation 1) and wait until it is truly
  // suspended inside its own access RPC call.
  const renderA=Console.render(argsA);
  await started[0].promise;

  // Only now start the fresh render (generation 2); let its access RPC
  // resolve and the whole call run to completion.
  const renderB=Console.render(argsB);
  await started[1].promise;
  resolved[1].resolve(access);
  await renderB;

  const paintedByB=root.innerHTML;
  assert.ok(paintedByB.includes('platform-console'),'render B should have painted the real shell');
  assert.ok(paintedByB.includes('#/from-fresh-b'),'render B\'s own marker must be present');
  assert.ok(!paintedByB.includes('#/from-stale-a'),'render A must not have painted yet');

  // Now let the STALE call's access RPC resolve late, and let render A finish.
  resolved[0].resolve(access);
  await renderA;

  assert.equal(root.innerHTML,paintedByB,
    'a late-resolving stale render() must not repaint root over a newer, already-rendered page');
  assert.ok(!root.innerHTML.includes('#/from-stale-a'),
    'the stale render\'s own marker must never reach root');
});
