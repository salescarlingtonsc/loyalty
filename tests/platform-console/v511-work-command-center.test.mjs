import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,Intl,Date,Map,Set,Proxy,Reflect};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

function occurrences(source,needle){
  let count=0,index=0;
  while((index=source.indexOf(needle,index))!==-1){count++;index+=needle.length}
  return count;
}

test('platform_command_center_v511 is called exactly once, from the command center renderer, never from a table read',async()=>{
  const source=await read('app/platform-console.js');
  assert.equal(occurrences(source,"rpc(sb,'platform_command_center_v511'"),1);
  const fnStart=source.indexOf('async function renderCommandCenterV511');
  const fnEnd=source.indexOf('\n  }\n',fnStart);
  const fnBody=source.slice(fnStart,fnEnd);
  assert.match(fnBody,/rpc\(sb,'platform_command_center_v511',\{p_limit:50\}\)/);
  assert.doesNotMatch(source,/\.from\(\s*['"]work_items_v511['"]\s*\)/);
  assert.doesNotMatch(source,/\.from\(\s*['"]work_item_events_v511['"]\s*\)/);
});

test('platform_list_work_v511 backs the Work queue and passes the resolved scope, not a client-chosen owner',async()=>{
  const source=await read('app/platform-console.js');
  assert.equal(occurrences(source,"rpc(sb,'platform_list_work_v511'"),1);
  assert.match(source,/rpc\(sb,'platform_list_work_v511',\{p_scope:scope,p_owner:null,p_limit:100\}\)/);
  // Team is refused (42501) for sales_staff on the server; the client
  // normalizes it to 'mine' before ever calling the RPC rather than calling
  // it and catching the error, per the house rule.
  const renderStart=source.indexOf('async function renderWorkV511');
  const renderBody=source.slice(renderStart,source.indexOf('\n  }\n',renderStart));
  assert.match(renderBody,/isSalesStaff&&filters\.scope==='team'\?'mine':filters\.scope/);
});

test('every v511 write RPC appears at exactly its intended call site with an idempotency key and an expected version where the contract requires one',async()=>{
  const source=await read('app/platform-console.js');
  assert.equal(occurrences(source,"rpc(sb,'platform_assign_work_item_v511'"),1);
  assert.match(source,/p_work_item:button\.dataset\.workClaim,p_expected_version:Number\(button\.dataset\.version\),\s*\n\s*p_owner:selfConsultant,p_queue:null,p_idempotency_key:idempotencyKey\(\)/);
  // One transition entry point serves Start, Wait, Block and Done — all four
  // call sites, no fifth.
  assert.equal(occurrences(source,"rpc(sb,'platform_transition_work_item_v511'"),4);
  assert.match(source,/p_to_state:'in_progress'/);
  assert.match(source,/p_to_state:'waiting'/);
  assert.match(source,/p_to_state:'blocked'/);
  assert.match(source,/p_to_state:'done'/);
  assert.equal(occurrences(source,"rpc(sb,'platform_create_work_item_v511'"),1);
  assert.equal(occurrences(source,"rpc(sb,'platform_get_business_360_v511'"),1);
  // Every mutation this file makes to work_items_v511 carries an idempotency
  // key, matching the RPCs' own p_idempotency_key contract.
  for(const rpcName of [
    'platform_assign_work_item_v511','platform_transition_work_item_v511',
    'platform_create_work_item_v511'
  ]){
    const pattern=new RegExp(`rpc\\(sb,'${rpcName}',\\{[\\s\\S]{0,400}?p_idempotency_key:idempotencyKey\\(\\)`,'g');
    const matches=source.match(pattern)||[];
    assert.ok(matches.length>=1,`${rpcName} call site(s) must pass p_idempotency_key:idempotencyKey()`);
  }
});

test('close actions (Wait, Block, Done) are offered only for origin_kind===native; a projected item gets a "Managed by" label and a deep link instead',async()=>{
  const source=await read('app/platform-console.js');
  const fnStart=source.indexOf('function v511WorkRowActionsHtml');
  const fnBody=source.slice(fnStart,source.indexOf('\n  }\n',fnStart));
  assert.match(fnBody,/if\(item\.origin_kind!=='native'\)\{/);
  assert.match(fnBody,/Managed by \{source\}/);
  // The native branch is reached only after the origin_kind!=='native' guard
  // returns — Claim/Start/Wait/Block/Done never render for a projected item.
  const nativeGuardIndex=fnBody.indexOf("origin_kind!=='native'");
  const returnIndex=fnBody.indexOf('return',nativeGuardIndex);
  const claimIndex=fnBody.indexOf('data-work-claim');
  const startIndex=fnBody.indexOf('data-work-start');
  const waitIndex=fnBody.indexOf('data-work-wait');
  const blockIndex=fnBody.indexOf('data-work-block');
  const doneIndex=fnBody.indexOf('data-work-done');
  for(const index of [claimIndex,startIndex,waitIndex,blockIndex,doneIndex]){
    assert.ok(index>returnIndex,'close/progress buttons must be declared after the native-only guard returns');
  }
  // The server itself refuses to close a non-native item (origin_kind<>'native'
  // in platform_transition_work_item_v511) — the deep link function is the
  // only path offered instead, and it knows all three projected origins.
  const linkStart=source.indexOf('function v511DeepLinkHash');
  const linkBody=source.slice(linkStart,source.indexOf('\n  }\n',linkStart));
  assert.match(linkBody,/sme_prospect_task/);
  assert.match(linkBody,/subscription_task/);
  assert.match(linkBody,/onboarding_item/);
});

test('v511DeepLinkHash routes each projected origin to its real system of record',async()=>{
  const api=await loadConsole();
  assert.match(
    api.v511DeepLinkHash({origin_kind:'sme_prospect_task',prospect_id:'p-1'}),
    /^#\/platform\/onboarding\?.*prospect=p-1/
  );
  assert.match(
    api.v511DeepLinkHash({origin_kind:'subscription_task',subject_name:'Acme Cafe'}),
    /^#\/platform\/subscription-operations\?search=Acme(%20|\+)Cafe$/
  );
  assert.match(
    api.v511DeepLinkHash({origin_kind:'onboarding_item',subject_name:'Acme Cafe'}),
    /^#\/platform\/onboarding\?.*search=Acme/
  );
  assert.equal(api.v511DeepLinkHash({origin_kind:'native'}),null);
  assert.equal(api.v511DeepLinkHash({origin_kind:'payment_exception'}),null);
});

test('Team is hidden from the Work tab strip for sales_staff and offered to every other role',async()=>{
  const api=await loadConsole();
  const salesStaffTabs=JSON.parse(JSON.stringify(api.v511WorkTabsFor(true).map(tab=>tab.key)));
  const otherRoleTabs=JSON.parse(JSON.stringify(api.v511WorkTabsFor(false).map(tab=>tab.key)));
  assert.deepEqual(salesStaffTabs,['mine','unassigned','overdue']);
  assert.deepEqual(otherRoleTabs,['mine','team','unassigned','overdue']);
  assert.ok(!salesStaffTabs.includes('team'));
});

test('workStateFromHash only accepts the four server-defined scopes and defaults unknown input to mine',async()=>{
  const api=await loadConsole();
  const state=hash=>JSON.parse(JSON.stringify(api.workStateFromHash(hash)));
  assert.deepEqual(state('#/platform/work'),{scope:'mine'});
  assert.deepEqual(state('#/platform/work?scope=team'),{scope:'team'});
  assert.deepEqual(state('#/platform/work?scope=unassigned'),{scope:'unassigned'});
  assert.deepEqual(state('#/platform/work?scope=overdue'),{scope:'overdue'});
  assert.deepEqual(state('#/platform/work?scope=bogus'),{scope:'mine'});
  assert.equal(api.V511_WORK_SCOPES.includes('mine'),true);
  assert.equal(api.V511_WORK_SCOPES.length,4);
});

test('Command center and Work resolve as routes without being module-gated route-registry entries',async()=>{
  const api=await loadConsole();
  // Neither view is a registry entry: adding one would force every role whose
  // onboarding|firms|reports grant already includes 'onboarding' to gain two
  // more entries in its exact visible-route list, which the pre-existing
  // route-inventory tests hard-code and which the v511 RPCs do not require
  // (app.v511_assert_work_reader() admits any active platform role, not a
  // module grant).
  assert.equal(api.routes.some(route=>route.key==='command-center'),false);
  assert.equal(api.routes.some(route=>route.key==='work'),false);
  assert.equal(api.isRoute('#/platform/command-center'),true);
  assert.equal(api.isRoute('#/platform/work'),true);
  assert.equal(api.isRoute('#/platform/work?scope=overdue'),true);
  assert.equal(api.routeKey('#/platform/command-center'),'command-center');
  assert.equal(api.routeKey('#/platform/work'),'work');
});

test('the render dispatcher reaches both views and never redirects their hash back to a registry route',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/if\(!task&&activeKey==='command-center'\)task=renderCommandCenterV511\(context\)/);
  assert.match(source,/if\(!task&&activeKey==='work'\)task=renderWorkV511\(context,workStateFromHash\(hash\)\)/);
  assert.match(source,/isV511DirectRoute\?\{key:requestedKey\}/);
  assert.match(source,/if\(!isV511DirectRoute&&activeKey!==requestedKey&&globalObject\.history\?\.replaceState\)/);
  assert.match(source,/if\(isV511DirectRoute\)context\.canWrite=true;/);
});

test('reason and attention chips tone blocked/overdue red, unassigned/inactive/stalled amber, and everything else neutral',async()=>{
  const api=await loadConsole();
  assert.equal(api.v511AttentionTone('blocked'),'no');
  assert.equal(api.v511AttentionTone('overdue'),'no');
  assert.equal(api.v511AttentionTone('payment_failed'),'no');
  assert.equal(api.v511AttentionTone('unassigned'),'new');
  assert.equal(api.v511AttentionTone('inactive_owner'),'new');
  assert.equal(api.v511AttentionTone('stalled'),'new');
  assert.equal(api.v511AttentionTone('missing_next_action'),'new');
  assert.equal(api.v511AttentionTone('due_today'),'off');
  assert.equal(api.v511AttentionTone('on_track'),'off');
  assert.equal(api.v511StateTone('blocked'),'no');
  assert.equal(api.v511StateTone('done'),'ok');
  assert.equal(api.v511StateTone('cancelled'),'off');
  assert.equal(api.v511StateTone('open'),'new');
});

test('every localized string this feature introduces has real Chinese and Malay copy, not an identity fallback',async()=>{
  const api=await loadConsole();
  const keys=[
    'Command center','Work','My work','Claim','Start','Wait','Block','Done',
    'New work item','Create work item','Business 360','Entitled',
    'Awaiting verified payment','Not live','Blocker','Timeline',
    'The operation is clear','No work in this queue',
    'This item changed since it was loaded. The list has been refreshed.',
    'Lead Follow Up','Commercial Review','Payment Exception','Not Needed','Superseded'
  ];
  for(const locale of ['zh-CN','ms']){
    api.setPlatformLocaleForTest(locale);
    for(const key of keys){
      assert.notEqual(api.platformText(key),key,`${locale} is missing a translation for "${key}"`);
    }
  }
  api.setPlatformLocaleForTest('en');
  for(const key of keys){
    assert.equal(api.platformText(key),key,`English must render the key itself for "${key}"`);
  }
});

test('the New work item form anchors to a business or a lead client-side too, before the RPC ever refuses an unanchored item',async()=>{
  const source=await read('app/platform-console.js');
  const fnStart=source.indexOf('function v511NewWorkItemModal');
  const fnBody=source.slice(fnStart,source.indexOf('\n  }\n',fnStart));
  assert.match(fnBody,/if\(!business&&!prospect\)throw new Error\(pt\('A work item must name a business or a lead\.'\)\)/);
  assert.match(fnBody,/p_work_type:form\.get\('work_type'\)/);
  assert.match(fnBody,/p_priority:0/);
});

test('a 40001 version conflict refreshes the list and announces the conflict instead of showing a stale row',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/function v511HandleActionError/);
  const helperStart=source.indexOf('async function v511HandleActionError');
  const helperBody=source.slice(helperStart,source.indexOf('\n  }\n',helperStart));
  assert.match(helperBody,/String\(error\?\.code\)==='40001'/);
  assert.match(helperBody,/await refresh\(\)/);
  assert.match(helperBody,/This item changed since it was loaded\. The list has been refreshed\./);
  // The Claim button handler uses the shared helper rather than reinventing
  // the conflict branch inline.
  assert.match(source,/await v511HandleActionError\(error,refresh,CUI,'The work item could not be claimed\.'\)/);
  assert.match(source,/await v511HandleActionError\(error,refresh,CUI,'The work item could not be started\.'\)/);
  // Each modal (Wait/Block/Done) independently detects 40001 so a conflict
  // there refreshes the list and closes the dialog rather than showing the
  // conflict as an ordinary in-modal validation error.
  for(const fnName of ['v511WaitModal','v511BlockModal','v511DoneModal']){
    const start=source.indexOf(`function ${fnName}`);
    const body=source.slice(start,source.indexOf('\n  }\n',start));
    assert.match(body,new RegExp("String\\(error\\?\\.code\\)==='40001'"),`${fnName} must special-case 40001`);
    assert.match(body,/await context\.refreshWork\(\)/,`${fnName} must refresh after a conflict`);
  }
});

test('command center rows navigate to Business 360 for a business anchor and to the prospect detail route otherwise',async()=>{
  const source=await read('app/platform-console.js');
  const fnStart=source.indexOf('function v511CommandCenterNavigate');
  const fnBody=source.slice(fnStart,source.indexOf('\n  }\n',fnStart));
  const businessIndex=fnBody.indexOf('businessId');
  const openBusinessIndex=fnBody.indexOf('openBusiness360V511(businessId,context)');
  const prospectIndex=fnBody.indexOf('prospectId){');
  assert.ok(businessIndex<openBusinessIndex,'business_id must be checked before opening Business 360');
  assert.ok(openBusinessIndex<prospectIndex,'business_id must be checked ahead of prospect_id, per the spec order');
  assert.match(fnBody,/onboardingHash\(defaultOnboardingFilters\(\),\{prospect:prospectId\}\)/);
});

test('the command center empty state reads as success, not as an ordinary empty table',async()=>{
  const source=await read('app/platform-console.js');
  const fnStart=source.indexOf('function v511CommandCenterHtml');
  const fnBody=source.slice(fnStart,source.indexOf('\n  }\n',fnStart));
  assert.match(fnBody,/iconName:'check',title:'The operation is clear'/);
});

test('Business 360 reports entitlement and liveness as two separate facts, never merged into one status',async()=>{
  const source=await read('app/platform-console.js');
  const fnStart=source.indexOf('function v511Business360Html');
  const fnBody=source.slice(fnStart,source.indexOf('\n  }\n',fnStart));
  assert.match(fnBody,/entitlement\.entitled\?pt\('Entitled'\):pt\('Awaiting verified payment'\)/);
  assert.match(fnBody,/entitlement\.live\?pt\('Live'\):pt\('Not live'\)/);
  // Two independent CUI.status() badges, not one derived label.
  const statusCalls=(fnBody.match(/CUI\.status\(/g)||[]).length;
  assert.ok(statusCalls>=2);
});
