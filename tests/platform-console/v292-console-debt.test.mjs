// V292 — the platform console's silent-truncation debt (audit S4) and the demo
// request queue (audit S8).
//
// Two failure shapes are pinned here, because both were invisible rather than
// broken: a list that returned exactly its limit and said nothing, and a "Request
// a demo" button that recorded nothing at all. A regression in either would look
// like a perfectly healthy screen, so only a test can hold them.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,Intl,Date,Map,Set,Proxy,Reflect,Math,Number,String,Boolean,Array,JSON};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

test('a window that came back full is reported as incomplete, not as the whole list',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');

  // A short page is complete: there is nothing to disclose and no button to draw.
  const complete=api.platformWindowState({loaded:12,limit:50,ceiling:250});
  assert.equal(complete.more,false);
  assert.equal(api.platformWindowHtml(complete,{buttonId:'x'}),'');

  // A full page is the only evidence a cursorless reader gives that more exist.
  const partial=api.platformWindowState({loaded:50,limit:50,ceiling:250});
  assert.equal(partial.more,true);
  assert.equal(partial.canGrow,true);
  assert.equal(partial.nextLimit,100);

  // At the server's own ceiling there is no honest button, so none is drawn --
  // but the disclosure must remain. Silence here is the original defect.
  const capped=api.platformWindowState({loaded:250,limit:250,ceiling:250});
  assert.equal(capped.more,true);
  assert.equal(capped.canGrow,false);
  assert.equal(capped.capped,true);
  const cappedHtml=api.platformWindowHtml(capped,{buttonId:'shouldNotAppear',cappedAdvice:'Open a single firm from the exception queue to reach a billing record that is not listed.'});
  assert.match(cappedHtml,/data-platform-window="capped"/);
  assert.match(cappedHtml,/Showing the first 250/);
  assert.match(cappedHtml,/Open a single firm from the exception queue/);
  assert.doesNotMatch(cappedHtml,/shouldNotAppear/,'a capped window must not offer a button that cannot load anything');

  // The growable shape does draw one, and it is wired to a real id.
  const growHtml=api.platformWindowHtml(partial,{buttonId:'partnerObligationsLoadMore'});
  assert.match(growHtml,/data-platform-window="growable"/);
  assert.match(growHtml,/id="partnerObligationsLoadMore"/);
  assert.match(growHtml,/Load 50 more/);
});

test('a reader that publishes has_more is believed over the row count',async()=>{
  const api=await loadConsole();
  // v255 returns has_more. A page of 40 out of a limit of 100 still means "more"
  // when the server says so -- inferring completeness from the row count alone
  // would silently hide months of marketing usage.
  const reportedMore=api.platformWindowState({loaded:40,limit:100,ceiling:1000,reported:true});
  assert.equal(reportedMore.more,true);
  assert.equal(reportedMore.canGrow,true);
  // And the converse: a page that happens to be exactly full is complete when the
  // server says it is, so the console does not offer a pointless extra read.
  const reportedDone=api.platformWindowState({loaded:100,limit:100,ceiling:1000,reported:false});
  assert.equal(reportedDone.more,false);
});

test('every flat-limit list discloses its window and grows only where the server allows',async()=>{
  const source=await read('app/platform-console.js');

  // Billing and Subscription operations are already at their server ceilings
  // (v89 refuses >250, v156 refuses >500), so they disclose and advise.
  assert.match(source,/const billingWindow=platformWindowState\(\{loaded:rows\.length,limit:250,ceiling:250\}\)/);
  assert.match(source,/platformWindowHtml\(billingWindow,\{cappedAdvice:'Open a single firm from the exception queue to reach a billing record that is not listed\.'\}\)/);
  assert.match(source,/const subscriptionWindow=platformWindowState\(\{loaded:asArray\(payload\.subscriptions\)\.length,limit:500,ceiling:500\}\)/);
  assert.match(source,/platformWindowHtml\(subscriptionWindow,\{cappedAdvice:'Search for the business by name/);
  // Customer lifecycle reads the same 500-row window and must disclose it too.
  assert.match(source,/platformWindowHtml\(platformWindowState\(\{loaded:rows\.length,limit:500,ceiling:500\}\)/);

  // Marketing usage, partner obligations and the application queue can genuinely
  // ask for more, so they get a button and a ceiling that matches the RPC.
  assert.match(source,/const MARKETING_ENGAGEMENT_CEILING=1000;/);
  assert.match(source,/const MARKETING_DEMAND_CEILING=200;/);
  assert.match(source,/p_limit:engagementLimit/);
  assert.match(source,/p_limit:demandLimit/);
  assert.match(source,/buttonId:'marketingUsageLoadMore'/);
  assert.match(source,/buttonId:'marketingDemandLoadMore'/);
  assert.match(source,/const PARTNER_OBLIGATION_CEILING=500;/);
  assert.match(source,/platform_list_partner_obligations_v282',\{p_limit:windowLimit\}/);
  assert.match(source,/buttonId:'partnerObligationsLoadMore'/);
  assert.match(source,/const BUSINESS_APPLICATION_CEILING=250;/);
  assert.match(source,/p_status:'submitted',p_search:filters\.search\|\|null,p_limit:applicationLimit/);
  assert.match(source,/p_status:'approved',p_search:filters\.search\|\|null,p_limit:applicationLimit/);
  assert.match(source,/buttonId:'platformApplicationsLoadMore'/);

  // The hardcoded limits these replaced must be gone, or the disclosure would be
  // describing a window the code no longer asks for.
  assert.doesNotMatch(source,/platform_engagement_monthly_v255',\{p_from:active\.from,p_to:active\.to,p_businesses:null,p_limit:100\}/);
  assert.doesNotMatch(source,/platform_list_partner_obligations_v282',\{p_limit:200\}/);
  assert.doesNotMatch(source,/Showing the newest 100 applications/);
});

test('the ninth website signup is reachable, and the tab badge counts every one',async()=>{
  const source=await read('app/platform-console.js');
  // The slice that made rows 9+ unreachable -- and under-counted the badge --
  // must not come back.
  assert.doesNotMatch(source,/\)\)\.slice\(0,8\);\n  \}/,'paymentManagedSignupItems must not truncate its own result');
  assert.match(source,/const PAYMENT_MANAGED_SIGNUP_PREVIEW=8;/);
  assert.match(source,/data-signup-overflow/);
  assert.match(source,/id="platformSignupsShowAll"/);
  assert.match(source,/pt\('Show all \{count\}',\{count:rows\.length\}\)/);
  // The reveal is local: nothing is refetched, so the operator keeps their place.
  assert.match(source,/main\.querySelectorAll\('\[data-signup-overflow\]'\)\.forEach\(row=>\{row\.hidden=expanded\}\)/);
});

test('demo requests are a real super-admin queue on a real paged reader',async()=>{
  const api=await loadConsole();
  const source=await read('app/platform-console.js');

  const route=api.routes.find(entry=>entry.key==='demo-requests');
  assert.ok(route,'the console must expose a demo-requests route');
  assert.equal(route.hash,'#/platform/demo-requests');
  assert.equal(route.superAdminOnly,true);
  assert.equal(route.moduleKey,undefined,'a demo request has no tenant, so no tenant grant may open it');

  // An admin without super-admin rights must not see it at all.
  const admin=api.normalizePlatformAccess({role:'admin',scope:'all',module_perms:{}});
  assert.equal(api.visibleRoutes(admin).some(entry=>entry.key==='demo-requests'),false);
  const superAdmin=api.normalizePlatformAccess({role:'super_admin',scope:'all',module_perms:{}});
  assert.equal(api.visibleRoutes(superAdmin).some(entry=>entry.key==='demo-requests'),true);

  // This reader takes a real offset and returns a real total, so the queue pages
  // rather than growing a limit and guessing.
  assert.match(source,/platform_list_demo_requests_v292',\{\s*p_status:status\|\|null,p_search:search\|\|null,\s*p_limit:PLATFORM_WINDOW_STEP,p_offset:carried\.length/);
  assert.match(source,/const total=Number\(payload\.total_count\?\?items\.length\)/);
  assert.match(source,/pt\('Showing \{shown\} of \{count\}\.',/);
  assert.match(source,/if\(!task&&activeKey==='demo-requests'\)task=renderDemoRequests\(context\)/);
});

test('marking a demo request contacted captures what was said; archiving is one click',async()=>{
  const api=await loadConsole();
  const source=await read('app/platform-console.js');
  const CUI={
    status:(label,tone)=>`<span data-tone="${tone}">${label}</span>`,
    emptyState:({title})=>`<div data-empty="${title}"></div>`
  };

  assert.match(api.demoRequestQueueHtml([],CUI,true),/data-empty="No demo requests yet"/);

  const html=api.demoRequestQueueHtml([{
    id:'11111111-1111-4111-8111-111111111111',
    contact_name:'Priya Menon',business_name:'Kopi Corner',
    contact_email:'priya@kopicorner.sg',contact_phone:'81234567',
    sector:'F&B',note:'Wants to see loyalty.',status:'new',created_at:'2026-08-12T02:00:00Z'
  }],CUI,true);
  assert.match(html,/Kopi Corner/);
  assert.match(html,/priya@kopicorner\.sg/);
  assert.match(html,/data-demo-contacted="11111111-1111-4111-8111-111111111111"/);
  assert.match(html,/data-demo-archive="11111111-1111-4111-8111-111111111111"/);

  // A read-only operator gets the queue but not the controls.
  const readOnly=api.demoRequestQueueHtml([{
    id:'2',contact_name:'A B',business_name:'C D',contact_phone:'81234567',status:'new'
  }],CUI,false);
  assert.doesNotMatch(readOnly,/data-demo-contacted/);
  assert.doesNotMatch(readOnly,/data-demo-archive/);

  // Contacted is the state that carries a story, so it goes through a modal that
  // demands one; archive and reopen do not remove anyone's access and stay direct.
  assert.match(source,/function demoRequestOutcomeModal\(context,request,onDone\)/);
  assert.match(source,/p_request:request\.id,p_status:'contacted',p_note:form\.get\('note'\)/);
  assert.match(source,/p_status:'archived',p_note:null/);
  assert.match(source,/p_status:'new',p_note:null/);
});

test('the V292 migration keeps the demo queue platform-only and the capture write-only',async()=>{
  const sql=await read('db/migrations/20260812_nestly_v292_demo_requests.sql');

  // The table is cross-tenant prospect data: RLS on, zero policies, no browser ACL.
  assert.match(sql,/alter table public\.demo_requests_v292 enable row level security;/);
  assert.doesNotMatch(sql,/create policy[\s\S]*demo_requests_v292/);
  assert.match(sql,/revoke all privileges on table public\.demo_requests_v292\s*\n\s*from public, anon, authenticated;/);

  // A request nobody can answer is not a lead.
  assert.match(sql,/constraint demo_requests_v292_contactable/);
  assert.match(sql,/check \(contact_email is not null or contact_phone is not null\)/);

  // The capture is anon-callable on purpose; the two platform readers never are.
  assert.match(sql,/grant execute on function public\.submit_demo_request_v292\(text, text, text, text, text, text\)\s*\n\s*to anon, authenticated;/);
  assert.match(sql,/grant execute on function public\.platform_list_demo_requests_v292\(text, text, integer, integer\)\s*\n\s*to authenticated;/);
  assert.doesNotMatch(sql,/grant execute on function public\.platform_list_demo_requests_v292[^;]*anon/);
  assert.doesNotMatch(sql,/grant execute on function public\.platform_mark_demo_request_v292[^;]*anon/);

  // Anon-callable therefore means self-throttled, following report_client_error_v177.
  assert.match(sql,/interval '1 hour'/);
  assert.match(sql,/if v_recent >= 200 then/);
  assert.match(sql,/interval '30 minutes'/);
  assert.match(sql,/duplicate_ignored/);

  // Both platform functions hold the super-admin gate, not a tenant gate.
  const superAdminGates=[...sql.matchAll(/if not app\.is_super_admin\(\) then/g)];
  assert.equal(superAdminGates.length,2);

  // The list reader must return the total, or the console cannot page honestly.
  assert.match(sql,/'total_count', v_total/);
  assert.match(sql,/'has_more', \(p_offset \+ p_limit\) < v_total/);
});
