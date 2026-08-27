/* nestly_C7 — WhatsApp capabilities panel on the superadmin platform console
 * (System health / #/platform/automation).
 *
 * WHY THIS TEST EXISTS. The panel is reached by a super admin clicking
 * "System health" in the platform rail (or navigating #/platform/automation),
 * where renderAutomation() now fetches public.platform_list_capability_grants_v557
 * and renders whatsappCapabilitiesSectionHtml(). This loads the REAL
 * platform-console.js module in a vm sandbox (same technique the rest of this
 * directory uses — no jsdom is available in this repo) and executes the real
 * exported render/payload functions against stubbed RPC-shaped data, rather
 * than grepping the source for strings.
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

// A minimal CUI stub in the same shape the rest of this directory's tests
// use (see v105-admin-task-closure.test.mjs) — just enough for the render
// functions under test to produce inspectable HTML.
function stubCUI(){
  return {
    card:({title,description,body})=>`<section data-card="${title}"><p>${description||''}</p>${body}</section>`,
    table:({caption,headers,rows})=>`<table data-caption="${caption||''}"><thead>${headers.map(h=>`<th>${h}</th>`).join('')}</thead><tbody>${rows.map(row=>`<tr>${row.map(cell=>`<td>${cell}</td>`).join('')}</tr>`).join('')}</tbody></table>`,
    emptyState:({title,body})=>`<div data-empty-state><b>${title}</b><p>${body}</p></div>`,
    status:(text,tone)=>`<span class="pill ${tone}">${text}</span>`,
    field:({id,label})=>`<div class="cui-field" data-field-id="${id}"><label>${label}</label></div>`
  };
}

const ROW_CUBBLY_SUPPORT={
  business_id:'biz-cubbly',business_name:'Cubbly Cafe',
  capability_key:'whatsapp_support_reply',enabled:true,
  limit_count:50,limit_unlimited:false,limit_period:'daily',
  used_this_period:12,version:7
};
const ROW_CUBBLY_RETENTION={
  business_id:'biz-cubbly',business_name:'Cubbly Cafe',
  capability_key:'whatsapp_retention',enabled:false,
  limit_count:null,limit_unlimited:true,limit_period:'monthly',
  used_this_period:0,version:2
};
const SUPER_ADMIN_ACCESS=Object.freeze({role:'super_admin',modulePerms:{},scope:'all'});
const ADMIN_ACCESS=Object.freeze({role:'admin',modulePerms:{automation:'rw'},scope:'all'});
const SALES_STAFF_ACCESS=Object.freeze({role:'sales_staff',modulePerms:{automation:'rw'},scope:'own_created_or_assigned'});

test('the panel renders one row per business/capability grant from stubbed list data', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  const html = Console.whatsappCapabilitiesPanelHtml(
    [ROW_CUBBLY_SUPPORT, ROW_CUBBLY_RETENTION], CUI, true
  );

  assert.match(html, /WhatsApp capabilities/, 'the panel must carry its own title');
  assert.match(html, /Cubbly Cafe/);
  assert.match(html, /Support reply/, 'the support-reply capability must have a readable label');
  assert.match(html, /Retention/, 'the retention capability must have a readable label');
  // one row per grant (the stub's <thead> carries no <tr>, only <tbody> rows do)
  const dataRows = (html.match(/<tr>/g) || []).length;
  assert.equal(dataRows, 2, 'exactly one row per capability grant');
  assert.match(html, /50 \/ day/, 'a bounded daily limit is rendered as count / period');
  assert.match(html, /Unlimited/, 'an unlimited grant says so instead of printing a blank limit');
  assert.match(html, />12<|>0</, 'usage-this-period must be visible');
  assert.match(html, /data-capability-edit="biz-cubbly"/, 'each writable row exposes its edit control');
});

test('an empty grant list renders the empty state, not a blank table', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  const html = Console.whatsappCapabilitiesPanelHtml([], CUI, true);
  assert.match(html, /data-empty-state/);
  assert.doesNotMatch(html, /<table/);
});

test('canWrite=false hides the edit control from every row', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  const html = Console.whatsappCapabilitiesPanelHtml([ROW_CUBBLY_SUPPORT], CUI, false);
  assert.doesNotMatch(html, /data-capability-edit/);
});

test('the section is reachable for a super admin (System health route)', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  const html = Console.whatsappCapabilitiesSectionHtml([ROW_CUBBLY_SUPPORT], CUI, SUPER_ADMIN_ACCESS);
  assert.match(html, /WhatsApp capabilities/);
  assert.match(html, /data-capability-edit/, 'a super admin gets the write control too');
});

test('a non-superadmin path shows nothing — not even a read-only table', async () => {
  const Console = await loadConsole();
  const CUI = stubCUI();
  for (const access of [ADMIN_ACCESS, SALES_STAFF_ACCESS, null, undefined]) {
    const html = Console.whatsappCapabilitiesSectionHtml([ROW_CUBBLY_SUPPORT], CUI, access);
    assert.equal(html, '', `role ${access?.role ?? access} must render nothing for the capabilities panel`);
  }
});

test('the toggle/edit submission invokes platform_set_capability_grant_v518 with the row\'s own version', async () => {
  const Console = await loadConsole();
  const calls = [];
  const stubSb = {
    rpc: (name, args) => {
      calls.push({name, args});
      return Promise.resolve({data: {ok: true}, error: null});
    }
  };

  // Flip ROW_CUBBLY_SUPPORT's toggle off, keep its limit, and supply the
  // required change note — the same shape the edit modal's form submission
  // builds from the DOM.
  await Console.submitWhatsappCapabilityGrant(stubSb, ROW_CUBBLY_SUPPORT, {
    enabled: false,
    limitUnlimited: false,
    limitCount: '50',
    limitPeriod: 'daily',
    note: 'Pausing support replies pending a WABA review.'
  });

  assert.equal(calls.length, 1, 'exactly one RPC call must be made');
  assert.equal(calls[0].name, 'platform_set_capability_grant_v518');
  assert.deepEqual({...calls[0].args}, {
    p_business: 'biz-cubbly',
    p_capability: 'whatsapp_support_reply',
    p_enabled: false,
    p_limit_count: 50,
    p_limit_period: 'day',
    p_note: 'Pausing support replies pending a WABA review.',
    p_expected_version: 7,
    p_limit_unlimited: false
  });
});

test('marking a grant unlimited nulls the limit count regardless of a stray input value', async () => {
  const Console = await loadConsole();
  const calls = [];
  const stubSb = {rpc: (name, args) => { calls.push({name, args}); return Promise.resolve({data: null, error: null}); }};

  await Console.submitWhatsappCapabilityGrant(stubSb, ROW_CUBBLY_RETENTION, {
    enabled: true, limitUnlimited: true, limitCount: '999', limitPeriod: 'monthly',
    note: 'Owner requested unlimited retention sends for the launch week.'
  });

  assert.equal(calls[0].args.p_limit_count, null, 'unlimited must win over a stray count value');
  assert.equal(calls[0].args.p_limit_unlimited, true);
  assert.equal(calls[0].args.p_expected_version, 2, 'must guard on THIS row\'s version, not another row\'s');
});

test('the payload builder never sends an RPC by itself (pure function, no side effects)', async () => {
  const Console = await loadConsole();
  const payload = Console.whatsappCapabilityGrantPayload(ROW_CUBBLY_SUPPORT, {
    enabled: true, limitUnlimited: false, limitCount: '100', limitPeriod: 'monthly',
    note: 'Raising the monthly cap.'
  });
  assert.deepEqual({...payload}, {
    p_business: 'biz-cubbly',
    p_capability: 'whatsapp_support_reply',
    p_enabled: true,
    p_limit_count: 100,
    p_limit_period: 'month',
    p_note: 'Raising the monthly cap.',
    p_expected_version: 7,
    p_limit_unlimited: false
  });
});
