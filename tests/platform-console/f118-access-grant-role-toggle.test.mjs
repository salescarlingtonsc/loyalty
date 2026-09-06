/* Audit finding F118 — accessGrantModal's updateRoleHelp() forcibly
 * overwrites every per-module <select> when Role is switched to Sales
 * staff (overview='r', onboarding='rw', firms='r', everything else='off').
 * Switching Role back to Admin only re-enabled those selects
 * (`if(!sales){select.disabled=false;return}`) — it never restored their
 * VALUES, so an operator who tries Sales staff then switches back to Admin
 * before saving sees a role of "Admin" with stale, mostly-off module
 * permissions unless they manually re-check every row.
 *
 * This loads the REAL platform-console.js in a vm sandbox against a real
 * (if small) parsed-HTML mini-DOM (tests/platform-console/helpers/
 * mini-dom.mjs — this repo has no jsdom), drives it through the real
 * render() dispatcher to Platform access, clicks the real "Add access"
 * button to open the real accessGrantModal(), and exercises the real
 * roleSelect.onchange handler exactly as a browser would.
 */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';
import {createFakeDocument} from './helpers/mini-dom.mjs';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(fakeDocument){
  const source=await read('app/platform-console.js');
  const context={
    Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect,console,
    document:fakeDocument
  };
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

function stubCUI(){
  return {
    icon:name=>`<i>${name}</i>`,
    pageHeader:({title,actions})=>`<h1>${title||''}</h1>${actions||''}`,
    card:({title,body})=>`<section>${title||''}${body||''}</section>`,
    table:({rows})=>`<table>${(rows||[]).length}</table>`,
    emptyState:({title})=>`<div data-empty>${title||''}</div>`,
    errorState:({title,message})=>`<div class="err">${title||''}:${message||''}</div>`,
    loadingState:({title})=>`<div class="loading">${title||''}</div>`,
    status:text=>`<span>${text}</span>`,
    focusRoute:()=>{},
    announce:()=>{},
    activateDialog:overlay=>()=>overlay.remove(),
    field:opts=>{
      if(opts.control==='select'){
        const options=(opts.options||[]).map(o=>
          `<option value="${o.value}"${o.selected?' selected':''}>${o.label}</option>`
        ).join('');
        return `<select id="${opts.id}" ${opts.attributes||''}>${options}</select>`;
      }
      if(opts.control==='textarea')return `<textarea id="${opts.id}" ${opts.attributes||''}></textarea>`;
      return `<input id="${opts.id}" type="${opts.type||'text'}" value="${opts.value||''}" ${opts.attributes||''}>`;
    }
  };
}

test('switching Role from Sales staff back to Admin restores the original per-module permission values, not just enabling the controls',async()=>{
  const {document}=createFakeDocument();
  const Console=await loadConsole(document);
  const root={
    isConnected:true,_html:'',
    querySelector(){return document.body.querySelector('#platformMain')},
    querySelectorAll(){return []}
  };
  Object.defineProperty(root,'innerHTML',{
    get(){return root._html},
    set(v){
      root._html=v;
      // Route root writes through the same mini-DOM body so #platformMain
      // is a real, queryable element (render() writes shellHtml into root).
      document.body.innerHTML=v;
    }
  });

  const access={role:'super_admin',module_perms:{},scope:'all'};
  const sb={
    rpc:async(name)=>{
      if(name==='get_workspace_locale_preference_v97')return {data:{locale:'en',version:1},error:null};
      if(name==='platform_list_my_access_v89')return {data:access,error:null};
      if(name==='platform_list_access_grants_v89')return {data:{items:[]},error:null};
      throw new Error(`unexpected rpc ${name}`);
    }
  };

  const CUI=stubCUI();
  await Console.render({
    root,sb,CUI,brand:{},hash:'#/platform/access',
    isCurrent:()=>true,onSignOut:()=>{},workspaceHash:'#/'
  });

  const main=document.body.querySelector('#platformMain');
  const addAccess=main.querySelector('#platformAddAccess');
  assert.ok(addAccess,'the real Add access button must be present');
  addAccess.onclick();

  const overlay=document.body.children[document.body.children.length-1];
  const roleSelect=overlay.querySelector('#platformAccessRole');
  assert.equal(roleSelect.value,'admin','a brand-new grant defaults to Admin');

  const moduleSelect=key=>overlay.querySelector(`[data-access-module="${key}"]`).querySelector('select');
  const moduleValue=key=>moduleSelect(key).value;
  const moduleDisabled=key=>moduleSelect(key).disabled;

  // Every module starts at 'rw' (the seed default for a new admin grant).
  assert.equal(moduleValue('overview'),'rw');
  assert.equal(moduleValue('billing'),'rw');
  assert.equal(moduleDisabled('overview'),false);

  // Try Sales staff — every module is forced and disabled.
  roleSelect.value='sales_staff';
  roleSelect.onchange();
  assert.equal(moduleValue('overview'),'r');
  assert.equal(moduleValue('onboarding'),'rw');
  assert.equal(moduleValue('firms'),'r');
  assert.equal(moduleValue('billing'),'off');
  assert.equal(moduleDisabled('billing'),true);

  // Change their mind — switch back to Admin WITHOUT touching any module row.
  roleSelect.value='admin';
  roleSelect.onchange();

  assert.equal(moduleDisabled('overview'),false,'modules must be re-enabled');
  assert.equal(moduleValue('overview'),'rw',
    'switching back to Admin must restore the module value, not leave the Sales-staff-forced one');
  assert.equal(moduleValue('onboarding'),'rw');
  assert.equal(moduleValue('firms'),'rw',
    'firms was forced to "r" under Sales staff — Admin must not silently keep that narrowed value');
  assert.equal(moduleValue('billing'),'rw',
    'billing was forced to "off" under Sales staff — Admin must not silently keep that narrowed value');
  assert.equal(moduleValue('commissions'),'rw');
  assert.equal(moduleValue('sectors'),'rw');
  assert.equal(moduleValue('automation'),'rw');
});
