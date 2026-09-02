/* Audit finding F130 — a super admin had no working UI to extend a trial or
 * manually unpause a dunning-locked workspace, even though the server RPCs
 * (public.platform_adjust_subscription_v622, public.platform_set_workspace_
 * pause_v622 — db/migrations/20260830_nestly_v622_sa_writes_become_rpcs.sql)
 * already existed and enforced everything server-side: super_admin_required,
 * a >=8-character reason ('a reason of at least 8 characters is required'),
 * and a 180-day cap on the new trial date. 15 trialing tenants expire between
 * 5 and 14 September 2026.
 *
 * Same technique as v574-retention-holds-panel.test.mjs (no jsdom in this
 * repo): load the real platform-console.js in a vm sandbox and exercise the
 * exported pure payload builders / submit wrappers / result-merge functions
 * against stubbed RPC-shaped data, plus companyDetailHtml's rendering of the
 * new action buttons.
 */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

function stubCUI(){
  return {
    icon:name=>`<i>${name}</i>`,
    card:({title,description,body})=>`<section data-card="${title}"><p>${description||''}</p>${body}</section>`,
    table:({caption,headers,rows})=>`<table data-caption="${caption||''}"><thead>${headers.map(h=>`<th>${h}</th>`).join('')}</thead><tbody>${rows.map(row=>`<tr>${row.map(cell=>`<td>${cell}</td>`).join('')}</tr>`).join('')}</tbody></table>`,
    emptyState:({title,body})=>`<div data-empty-state><b>${title}</b><p>${body}</p></div>`,
    loadingState:({title,body})=>`<div><h3>${title}</h3><p>${body}</p></div>`,
    errorState:({title,message})=>`<div><h3>${title}</h3><p>${message}</p></div>`
  };
}

const chasedFirm={
  company:{id:'biz-kopi',name:'Kopi Lab',sector:'cafe',currency:'SGD',branch_count:1,seat_count:2},
  subscription:{status:'trialing',billing_cadence:'monthly',currency:'SGD',
    trial_ends_at:'2026-09-05T00:00:00+08:00',workspace_paused:false},
  outstanding:{open_invoice_count:0,balance_due_cents:0},
  contacts:[],payments:[],consultant:null
};

test('subscriptionReasonError enforces the server\'s own >=8-character rule and reuses its exact message', async()=>{
  const Console=await loadConsole();
  assert.equal(Console.subscriptionReasonError(''),'a reason of at least 8 characters is required');
  assert.equal(Console.subscriptionReasonError('short'),'a reason of at least 8 characters is required');
  assert.equal(Console.subscriptionReasonError('       '),'a reason of at least 8 characters is required',
    'whitespace-only must not count toward the length');
  assert.equal(Console.subscriptionReasonError('exactly8'),null,'8 characters is the server\'s own minimum, not 9');
  assert.equal(Console.subscriptionReasonError('  padded reason  '),null);
});

test('sgDateInputToIsoMidnight anchors a date-input value to SG local midnight, never the host timezone', async()=>{
  const Console=await loadConsole();
  // 2026-09-05 00:00 +08:00 is 2026-09-04 16:00 UTC.
  assert.equal(Console.sgDateInputToIsoMidnight('2026-09-05'),'2026-09-04T16:00:00.000Z');
  assert.equal(Console.sgDateInputToIsoMidnight(''),null);
  assert.equal(Console.sgDateInputToIsoMidnight('not-a-date'),null);
});

test('subscriptionAdjustPayload sends exactly the RPC\'s own argument names, trimmed', async()=>{
  const Console=await loadConsole();
  const payload=Console.subscriptionAdjustPayload('biz-kopi',{
    reason:'  extending for a pilot delay  ',trialEndsAt:'2026-09-04T16:00:00.000Z'
  });
  assert.deepEqual({...payload},{
    p_business:'biz-kopi',
    p_reason:'extending for a pilot delay',
    p_trial_ends_at:'2026-09-04T16:00:00.000Z',
    p_note:null
  });
});

test('submitSubscriptionAdjust calls platform_adjust_subscription_v622 with that exact shape', async()=>{
  const Console=await loadConsole();
  const calls=[];
  const stubSb={rpc:(name,args)=>{calls.push({name,args});return Promise.resolve({
    data:{business_id:'biz-kopi',trial_ends_at:'2026-09-04T16:00:00.000Z',entitlement:{trial_active:true}},
    error:null
  })}};

  const result=await Console.submitSubscriptionAdjust(stubSb,'biz-kopi',{
    reason:'extending for a pilot delay',trialEndsAt:'2026-09-04T16:00:00.000Z'
  });

  assert.equal(calls.length,1,'exactly one RPC call must be made');
  assert.equal(calls[0].name,'platform_adjust_subscription_v622');
  assert.deepEqual({...calls[0].args},{
    p_business:'biz-kopi',p_reason:'extending for a pilot delay',
    p_trial_ends_at:'2026-09-04T16:00:00.000Z',p_note:null
  });
  assert.equal(result.trial_ends_at,'2026-09-04T16:00:00.000Z');
});

test('workspacePausePayload and submitWorkspacePause send platform_set_workspace_pause_v622 with p_paused and a trimmed reason', async()=>{
  const Console=await loadConsole();
  assert.deepEqual({...Console.workspacePausePayload('biz-kopi',true,'  dunning day 14, no response  ')},{
    p_business:'biz-kopi',p_paused:true,p_reason:'dunning day 14, no response'
  });

  const calls=[];
  const stubSb={rpc:(name,args)=>{calls.push({name,args});return Promise.resolve({
    data:{business_id:'biz-kopi',workspace_paused:false,entitlement:{workspace_access:true}},error:null
  })}};
  const result=await Console.submitWorkspacePause(stubSb,'biz-kopi',false,'owner paid via bank transfer, releasing hold');
  assert.equal(calls[0].name,'platform_set_workspace_pause_v622');
  assert.deepEqual({...calls[0].args},{
    p_business:'biz-kopi',p_paused:false,p_reason:'owner paid via bank transfer, releasing hold'
  });
  assert.equal(result.workspace_paused,false);
});

test('the payload builders are pure — building a payload never calls the RPC by itself', async()=>{
  const Console=await loadConsole();
  // No stub sb is passed at all; if either builder tried to reach a network
  // client it would throw synchronously.
  Console.subscriptionAdjustPayload('biz-kopi',{reason:'a very good reason indeed'});
  Console.workspacePausePayload('biz-kopi',true,'a very good reason indeed');
});

test('applySubscriptionAdjustResult and applyWorkspacePauseResult re-derive the card from the RPC response, not the typed input', async()=>{
  const Console=await loadConsole();
  const detail={...chasedFirm,subscription:{...chasedFirm.subscription}};

  // The operator typed one date; the server is the one whose answer counts —
  // simulate it normalizing/clamping to a different instant than requested.
  const adjustResult={business_id:'biz-kopi',trial_ends_at:'2026-09-09T16:00:00.000Z',entitlement:{}};
  const afterAdjust=Console.applySubscriptionAdjustResult(detail,adjustResult);
  assert.equal(afterAdjust.subscription.trial_ends_at,'2026-09-09T16:00:00.000Z',
    'the merged detail must carry the RPC\'s own returned date, not whatever was requested');
  assert.equal(detail.subscription.trial_ends_at,'2026-09-05T00:00:00+08:00',
    'the original detail object must be left untouched (no local mutation)');

  const pauseResult={business_id:'biz-kopi',workspace_paused:true,entitlement:{}};
  const afterPause=Console.applyWorkspacePauseResult(detail,pauseResult);
  assert.equal(afterPause.subscription.workspace_paused,true);
  assert.equal(detail.subscription.workspace_paused,false,'again, no local mutation of the source object');
});

test('companyDetailHtml only exposes the two subscription actions to a caller that says it can manage the subscription', async()=>{
  const Console=await loadConsole();
  Console.setPlatformLocaleForTest('en');
  const CUI=Console.localizedPlatformCUI?Console.localizedPlatformCUI(stubCUI()):stubCUI();

  const withoutAccess=Console.companyDetailHtml(chasedFirm,CUI);
  assert.doesNotMatch(withoutAccess,/data-extend-trial/,'default (no options) must not show the write controls');
  assert.doesNotMatch(withoutAccess,/data-toggle-pause/);

  const withAccess=Console.companyDetailHtml(chasedFirm,CUI,{canManageSubscription:true});
  assert.match(withAccess,/data-extend-trial/,'a super admin caller must see Extend trial');
  assert.match(withAccess,/data-toggle-pause/,'a super admin caller must see the pause/unpause toggle');
  assert.match(withAccess,/Pause workspace/,'an unpaused workspace must offer to pause it');

  const pausedFirm={...chasedFirm,subscription:{...chasedFirm.subscription,workspace_paused:true}};
  const pausedHtml=Console.companyDetailHtml(pausedFirm,CUI,{canManageSubscription:true});
  assert.match(pausedHtml,/Unpause workspace/,'a paused workspace must offer to unpause it, not pause it again');
  assert.doesNotMatch(pausedHtml,/>Pause workspace</,'a paused workspace must not also offer Pause');
});

test('a business with no subscription yet shows neither action, even for a super admin', async()=>{
  const Console=await loadConsole();
  Console.setPlatformLocaleForTest('en');
  const CUI=Console.localizedPlatformCUI?Console.localizedPlatformCUI(stubCUI()):stubCUI();
  const html=Console.companyDetailHtml({
    company:{id:'biz-new',name:'New Firm'},subscription:null,
    outstanding:{open_invoice_count:0,balance_due_cents:0},contacts:[],payments:[],consultant:null
  },CUI,{canManageSubscription:true});
  assert.doesNotMatch(html,/data-extend-trial/);
  assert.doesNotMatch(html,/data-toggle-pause/);
});
