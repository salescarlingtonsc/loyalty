/* Audit finding F120 — supportTicketModal's "Set status" select is built
 * from ['in_progress','resolved','closed'].map(value=>({value,label:...}))
 * with no `selected` flag tied to ticket.status, so the browser always
 * pre-selects the FIRST option ('in_progress') no matter what the ticket's
 * real current status is. A super admin reopening a resolved/closed ticket
 * just to add a follow-up note, who clicks Save without noticing the
 * dropdown, silently reopens it.
 *
 * This loads the REAL platform-console.js in a vm sandbox against a real
 * parsed-HTML mini-DOM (tests/platform-console/helpers/mini-dom.mjs — this
 * repo has no jsdom), drives it through the real render() dispatcher to
 * Support requests, clicks the real "Open request" button for a RESOLVED
 * ticket, and reads the real <select>'s value the way a browser would
 * (the option carrying `selected`, or the first option if none does).
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
    table:({rows})=>`<table><tbody>${(rows||[]).map(row=>
      `<tr>${row.map(cell=>`<td>${cell}</td>`).join('')}</tr>`
    ).join('')}</tbody></table>`,
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

test('opening a RESOLVED support ticket must not default the status dropdown to "In progress"',async()=>{
  const {document}=createFakeDocument();
  const Console=await loadConsole(document);
  const root={
    isConnected:true,_html:'',
    querySelector(){return document.body.querySelector('#platformMain')},
    querySelectorAll(){return []}
  };
  Object.defineProperty(root,'innerHTML',{
    get(){return root._html},
    set(v){root._html=v;document.body.innerHTML=v}
  });

  const access={role:'super_admin',module_perms:{},scope:'all'};
  const ticket={
    id:'ticket-1',status:'resolved',submitted_at:'2026-08-01T00:00:00+08:00',
    requester_kind:'customer',contact_name:'Alex Tan',contact_email:'alex@example.com',
    contact_phone:'',business_name:'Kopi Lab',public_reference:'REQ-1',
    what_happened:'Could not redeem a reward.',resolution_note:'Fixed manually.',version:3
  };

  const sb={
    rpc:async(name)=>{
      if(name==='get_workspace_locale_preference_v97')return {data:{locale:'en',version:1},error:null};
      if(name==='platform_list_my_access_v89')return {data:access,error:null};
      if(name==='platform_list_support_tickets_v672'){
        return {data:{tickets:[ticket],open_count:0,has_more:false},error:null};
      }
      throw new Error(`unexpected rpc ${name}`);
    }
  };

  const CUI=stubCUI();
  await Console.render({
    root,sb,CUI,brand:{},hash:'#/platform/support',
    isCurrent:()=>true,onSignOut:()=>{},workspaceHash:'#/'
  });

  const main=document.body.querySelector('#platformMain');
  const openButton=main.querySelector('[data-support-ticket]');
  assert.ok(openButton,'the real "Open request" button must be present');
  openButton.onclick();

  const overlay=document.body.children[document.body.children.length-1];
  const statusSelect=overlay.querySelector('#supportTicketStatusV672');
  assert.ok(statusSelect,'the real status select must be present for a writable (super admin) viewer');
  assert.equal(statusSelect.value,'resolved',
    'the status dropdown must start on the ticket\'s real current status, not silently default to "In progress"');
});
