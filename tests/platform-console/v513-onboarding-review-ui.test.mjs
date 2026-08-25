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

// V513: platform_get_onboarding_review_v513 backs three surfaces (the firm
// onboarding drawer, Business 360, and per-item board hydration) and is
// called from exactly three places, none of them a .from() read.
test('platform_get_onboarding_review_v513 is read at exactly its three intended call sites',async()=>{
  const source=await read('app/platform-console.js');
  assert.equal(occurrences(source,"rpc(sb,'platform_get_onboarding_review_v513'"),3);
  assert.doesNotMatch(source,/\.from\(\s*['"][^'"]*v513[^'"]*['"]\s*\)/i);
  // (A) the firm onboarding drawer: fetched inside loadProspectDetail,
  // alongside — never instead of — the existing v79 checklist read.
  const loadStart=source.indexOf('async function loadProspectDetail');
  const loadBody=source.slice(loadStart,source.indexOf('\n  }\n',loadStart));
  assert.match(loadBody,/get_business_onboarding_v79',\{\s*p_business:prospect\.converted_business_id/);
  assert.match(loadBody,/platform_get_onboarding_review_v513',\{\s*p_business:prospect\.converted_business_id/);
  const v79Index=loadBody.indexOf('get_business_onboarding_v79');
  const v513Index=loadBody.indexOf('platform_get_onboarding_review_v513');
  assert.ok(v79Index<v513Index,'the v79 checklist read must still happen before the v513 review read');
  // A v513 failure here is captured onto the detail object, not thrown —
  // the drawer must still render from the v79 data it already has.
  assert.match(loadBody,/detail\.onboarding_review_error=error/);
  // (B) Business 360: fetched alongside platform_get_business_360_v511, and
  // captured (not thrown) so a v513 failure never blocks the 360 drawer.
  const bizStart=source.indexOf('async function openBusiness360V511');
  const bizBody=source.slice(bizStart,source.indexOf('\n  }\n',bizStart));
  assert.match(bizBody,/platform_get_business_360_v511',\{p_business:businessId,p_timeline_limit:20\}/);
  assert.match(bizBody,/platform_get_onboarding_review_v513',\{p_business:businessId\}\)\.then\(/);
  assert.match(bizBody,/v511Business360Html\(payload,CUI,review\.value,review\.error\)/);
  // (C) board hydration: one shared batching helper, Promise.allSettled so
  // one failing business (or the RPC not existing at all) never blocks the
  // rest of the page.
  const hydrateStart=source.indexOf('async function hydrateOnboardingReviewV513');
  const hydrateBody=source.slice(hydrateStart,source.indexOf('\n  }\n',hydrateStart));
  assert.match(hydrateBody,/Promise\.allSettled/);
  assert.match(hydrateBody,/rpc\(sb,'platform_get_onboarding_review_v513',\{p_business:businessId\}\)/);
});

test('the firm onboarding drawer gets a Submit for review control with a fresh idempotency key, following the v79 button pattern',async()=>{
  const source=await read('app/platform-console.js');
  assert.equal(occurrences(source,"'onboarding_submit_for_review_v513'"),1);
  assert.match(source,/data-onboarding-submit-review/);
  const wireStart=source.indexOf('function wireOnboardingChecklist');
  const wireBody=source.slice(wireStart,source.indexOf('\n  }\n',wireStart));
  assert.match(wireBody,/one\('\[data-onboarding-submit-review\]',button=>runChecklistButton\(\s*button,detail,context,'onboarding_submit_for_review_v513',\{p_business:businessId\},'Submitted for review\.'\s*\)\);/);
  // runChecklistButton is the shared v79 helper: it disables the button,
  // adds p_idempotency_key:idempotencyKey() itself, and re-enables on error —
  // reusing it means Submit for review gets that contract for free.
  const runStart=source.indexOf('async function runChecklistButton');
  const runBody=source.slice(runStart,source.indexOf('\n  }\n',runStart));
  assert.match(runBody,/button\.disabled=true/);
  assert.match(runBody,/rpc\(context\.sb,name,\{\.\.\.args,p_idempotency_key:idempotencyKey\(\)\}\)/);
  assert.match(runBody,/if\(button\.isConnected\)button\.disabled=false/);
});

test('platform_get_onboarding_metrics_v513 backs a super-admin-only Onboarding metrics tab, not a new route',async()=>{
  const source=await read('app/platform-console.js');
  assert.equal(occurrences(source,"rpc(sb,'platform_get_onboarding_metrics_v513'"),1);
  assert.match(source,/Object\.freeze\(\{key:'metrics',label:'Onboarding metrics',superAdminOnly:true\}\)/);
  const routesSection=source.slice(source.indexOf('const routes = Object.freeze(['),source.indexOf('  const platformModuleKeys'));
  assert.doesNotMatch(routesSection,/key:'metrics'/,'Onboarding metrics must stay a tab, not a route-registry entry');
  const metricsStart=source.indexOf('async function renderOnboardingMetricsV513');
  const metricsBody=source.slice(metricsStart,source.indexOf('\n  }\n',metricsStart));
  assert.match(metricsBody,/headers:\['Business','Platform touches','Merchant touches','Days to live'\]/);
  assert.doesNotMatch(metricsBody,/chart|Chart/,'the metrics panel is a plain table, no charts');
  assert.match(metricsBody,/showError\(main,error,CUI,'Onboarding metrics'\)/);
  // Reached only via the tab strip's own super-admin gate, exactly like
  // Signups/Applications/Demo requests.
  assert.match(source,/if\(tab==='metrics'\)\{\s*await renderOnboardingMetricsV513\(context,\{tabStrip\}\);\s*\}/);
});

test('onboardingTabsFor keeps Onboarding metrics hidden from every role but super_admin',async()=>{
  const api=await loadConsole();
  const everyoneElse=api.onboardingTabsFor(false).map(tab=>tab.key);
  const superAdminTabs=api.onboardingTabsFor(true).map(tab=>tab.key);
  assert.ok(!everyoneElse.includes('metrics'));
  assert.ok(superAdminTabs.includes('metrics'));
});

test('the readiness block covers all three next_actor values and degrades quietly on error or a missing checklist',async()=>{
  const api=await loadConsole();
  assert.equal(api.v513NextActorLabel('merchant'),api.platformText("Merchant's move"));
  assert.equal(api.v513NextActorLabel('peekaa'),api.platformText("Peekaa's move"));
  assert.equal(api.v513NextActorLabel('system'),api.platformText('System'));
  assert.equal(api.v513NextActorTone('merchant'),'new');
  assert.equal(api.v513NextActorTone('peekaa'),'no');
  assert.equal(api.v513NextActorTone('system'),'off');
  // No chip at all when a board item was never hydrated (no checklist, or
  // the RPC failed) — an absent badge, not a placeholder one.
  assert.equal(api.v513NextActorChip({},{status:()=>{throw new Error('must not be called')}}),'');
  let statusCalls=0;
  const CUI={status:(label,tone)=>{statusCalls+=1;return `${label}:${tone}`}};
  assert.equal(api.v513NextActorChip({onboarding_next_actor:'merchant'},CUI),`${api.platformText("Merchant's move")}:new`);
  assert.equal(statusCalls,1);
  // The drawer/360 readiness block degrades to one quiet note — never an
  // error card, never a thrown exception — on an RPC error or an empty payload.
  assert.equal(api.v513ReadinessHtml(null,new Error('boom'),CUI),api.v513ReadinessHtml(null,null,CUI));
  assert.match(api.v513ReadinessHtml(null,new Error('boom'),CUI),/data-v513-review-unavailable/);
  assert.doesNotMatch(api.v513ReadinessHtml(null,new Error('boom'),CUI),/undefined|\[object Object\]/);
});

test('every V513 localization key has real Chinese and Malay copy, not an identity fallback',async()=>{
  const api=await loadConsole();
  const keys=[
    "Merchant's move","Peekaa's move",'System','Ready','Not ready','Last evaluated',
    'Submitted for review','Not submitted','Platform touches','Merchant touches',
    'Submit for review','Onboarding review is not available yet.','Onboarding metrics',
    'Days to live','No onboarding metrics yet',
    'Metrics appear once a business has an onboarding checklist.'
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

test('the onboarding board surfaces the next_actor chip on every card and row representation',async()=>{
  const source=await read('app/platform-console.js');
  const cardStart=source.indexOf('function prospectCardHtml(item,CUI');
  const cardBody=source.slice(cardStart,source.indexOf('\n  }\n',cardStart));
  assert.match(cardBody,/v513NextActorChip\(item,CUI\)/);
  const compactStart=source.indexOf('function prospectCompactCardHtml');
  const compactBody=source.slice(compactStart,source.indexOf('\n  }\n',compactStart));
  assert.match(compactBody,/v513NextActorChip\(item,CUI\)/);
  const listStart=source.indexOf('function prospectListTableHtml');
  const listBody=source.slice(listStart,source.indexOf('\n  }\n',listStart));
  assert.match(listBody,/v513NextActorChip\(item,CUI\)/);
  // Both the super-admin pipeline and the scoped (sales_staff) pipeline
  // hydrate before rendering — the chip is not a super-admin-only feature.
  const renderOnboardingStart=source.indexOf("async function renderOnboarding(context,filters");
  const renderOnboardingBody=source.slice(renderOnboardingStart,source.indexOf('\n  }\n',source.indexOf('catch(error){showError(main,error,CUI,\'Onboarding\')}',renderOnboardingStart)));
  assert.match(renderOnboardingBody,/hydrateOnboardingReviewV513\(sb,items\)/);
  const scopedStart=source.indexOf('async function renderScopedOnboarding');
  const scopedBody=source.slice(scopedStart,source.indexOf('\n  }\n',scopedStart));
  assert.match(scopedBody,/hydrateOnboardingReviewV513\(sb,items\)/);
});

test('sales_staff module scope for onboarding is unchanged — no new module key was introduced',async()=>{
  const source=await read('app/platform-console.js');
  assert.doesNotMatch(source,/'onboarding_review'|'onboarding-review'/,'the v513 surface must ride the existing onboarding module grant');
});
