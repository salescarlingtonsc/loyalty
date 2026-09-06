/* Audit finding F138 — requestBillingCommand() closed the confirmation dialog
 * (controls.close();context.close?.()) BEFORE awaiting context.onCompleted(result).
 * The only caller that supplies onCompleted (the "Send Stripe Checkout" button
 * in the CRM prospect detail drawer) runs a second write,
 * platform_link_checkout_command_v156, with no try/catch of its own. When that
 * write throws (permission scope change, or the billing_commands row not yet
 * in a matching state), the thrown error propagated up into modal()'s own
 * try/catch, which writes the message into the confirm dialog's errorHost —
 * but that dialog (and its errorHost) had already been removed from the DOM
 * one line above, so the operator saw nothing at all and believed the
 * checkout was linked.
 *
 * The fix awaits context.onCompleted(result) BEFORE controls.close();
 * context.close?.() run, matching every other close()-then-write call site in
 * this file. This loads the REAL platform-console.js in a vm sandbox against
 * a real parsed-HTML mini-DOM (tests/platform-console/helpers/mini-dom.mjs)
 * and drives the REAL requestBillingCommand()/previewThenConfirm()/modal()
 * machinery end to end: fills and submits the real confirmation form, with a
 * failing onCompleted, and checks the dialog is still on screen with a
 * visible error — then submits again with a succeeding onCompleted and checks
 * it closes normally.
 */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';
import {createFakeDocument} from './helpers/mini-dom.mjs';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

// A minimal FormData that reads real <input>/<select>/<textarea> descendants of the mini-DOM
// form by `name`, matching what modal()'s onsubmit does with a real browser FormData. Checkboxes
// only contribute their value when a truthy `.checked` has been set on the element (the mini-DOM
// has no native checked/unchecked model), mirroring real browser semantics.
class TestFormData{
  constructor(form){this.form=form}
  get(name){
    const el=findByName(this.form,name);
    if(!el)return null;
    if((el.getAttribute('type')||'').toLowerCase()==='checkbox')return el.checked?(el.getAttribute('value')??'on'):null;
    return el.value;
  }
}
function findByName(node,name){
  for(const child of node.children){
    if(child.getAttribute('name')===name)return child;
    const found=findByName(child,name);
    if(found)return found;
  }
  return null;
}

async function loadConsole(fakeDocument){
  const source=await read('app/platform-console.js');
  const context={
    Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect,console,
    document:fakeDocument,FormData:TestFormData
  };
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

function stubCUI(){
  return {
    icon:name=>`<i>${name}</i>`,
    activateDialog:overlay=>()=>overlay.remove(),
    announce:()=>{}
  };
}

// Finds the just-opened confirmation dialog (the last child appended to <body>), ticks its
// "I reviewed this preview" checkbox, and submits the real form the way a click on Save would.
async function confirmOpenDialog(document){
  const overlay=document.body.children[document.body.children.length-1];
  const checkbox=findByName(overlay,'confirmed');
  assert.ok(checkbox,'the real confirmation checkbox must be present');
  checkbox.checked=true;
  const form=overlay.querySelector('[data-form]');
  assert.ok(form,'the real confirm form must be present');
  await form.onsubmit({preventDefault(){},currentTarget:form});
  return overlay;
}

test('a throwing onCompleted (the CRM link write) leaves the confirm dialog open with a visible error, instead of closing silently',async()=>{
  const {document}=createFakeDocument();
  const Console=await loadConsole(document);
  assert.equal(typeof Console.requestBillingCommand,'function','requestBillingCommand must be exported for this test');

  let closeCalled=false;
  const sb={
    rpc:async(name)=>{
      if(name==='request_billing_command_v124')return {status:'completed',command_id:'cmd-1'};
      throw new Error(`unexpected rpc ${name}`);
    }
  };
  const context={
    sb,CUI:stubCUI(),suppressRedirect:true,
    close:()=>{closeCalled=true},
    onCompleted:async()=>{throw new Error('platform_link_checkout_command_v156 failed: 22023')}
  };

  Console.requestBillingCommand('biz-1','create_checkout','annual',1000,context);
  // The confirmation dialog itself is opened synchronously by modal(); only submitting it
  // reaches the async onConfirm -> requestBillingCommand body under test.
  const overlay=await confirmOpenDialog(document);

  assert.equal(closeCalled,false,
    'context.close() must NOT run when onCompleted throws — the drawer must stay open');
  assert.ok(overlay.isConnected,
    'the confirm dialog must still be on screen so the operator can see what went wrong');
  const errorHost=overlay.querySelector('[data-error]');
  assert.ok(errorHost,'the error host must still exist (proves it was not removed before the write)');
  assert.match(errorHost.innerHTML,/could not be completed|failed/i,
    'the thrown error must be visibly rendered into the still-open dialog\'s error host');
});

test('a succeeding onCompleted still closes the confirm dialog and the caller-supplied context, as before',async()=>{
  const {document}=createFakeDocument();
  const Console=await loadConsole(document);

  let closeCalled=false,onCompletedRan=false;
  const main={
    isConnected:true,_html:'',
    querySelector:()=>null,querySelectorAll:()=>[]
  };
  Object.defineProperty(main,'innerHTML',{get(){return main._html},set(v){main._html=v}});
  const sb={
    rpc:async(name)=>{
      if(name==='request_billing_command_v124')return {status:'completed',command_id:'cmd-2'};
      if(name==='platform_get_billing_v125')return {data:[],error:null};
      if(name==='get_billing_plan_catalog_v125')return {data:[],error:null};
      throw new Error(`unexpected rpc ${name}`);
    }
  };
  const context={
    sb,CUI:stubCUI(),main,hash:'',suppressRedirect:true,
    close:()=>{closeCalled=true},
    onCompleted:async()=>{onCompletedRan=true}
  };

  Console.requestBillingCommand('biz-2','create_checkout','annual',1000,context);
  const overlay=await confirmOpenDialog(document);

  assert.ok(onCompletedRan,'onCompleted must still run on the success path');
  assert.ok(closeCalled,'context.close() must still run once onCompleted succeeds');
  assert.ok(!overlay.isConnected,'the confirm dialog must close on a successful completion, same as before the fix');
});
