import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
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

test('signups and applications are super-admin sub-modules',async()=>{
  const Console=await loadConsole();
  assert.deepEqual(Array.from(Console.onboardingTabsFor(true),tab=>tab.key),
    ['pipeline','signups','applications']);
  // A non-super-admin has no signup or application work, so they get the
  // pipeline alone — and no tab strip at all rather than a strip of one.
  assert.deepEqual(Array.from(Console.onboardingTabsFor(false),tab=>tab.key),['pipeline']);
  assert.equal(Console.onboardingTabStripHtml('pipeline',false,{}),'');
});

test('the tab strip marks the active section and carries its counts',async()=>{
  const Console=await loadConsole();
  Console.setPlatformLocaleForTest('en');
  const html=Console.onboardingTabStripHtml('signups',true,
    {pipeline:42,signups:3,applications:0});

  assert.match(html,/data-onboarding-tab="signups"[^>]*aria-pressed="true"/);
  assert.match(html,/data-onboarding-tab="pipeline"[^>]*aria-pressed="false"/);
  assert.match(html,/Pipeline \(42\)/);
  assert.match(html,/Signups \(3\)/);
  // Zero is a real answer — an empty queue must say so, not hide its count.
  assert.match(html,/Applications \(0\)/);
});

test('the tab round-trips through the URL and defaults to the pipeline',async()=>{
  const Console=await loadConsole();
  const base=Console.onboardingStateFromHash('#/platform/onboarding').filters;
  assert.equal(base.tab,'pipeline');

  const hash=Console.onboardingHash({...base,tab:'signups'});
  assert.match(hash,/tab=signups/);
  assert.equal(Console.onboardingStateFromHash(hash).filters.tab,'signups');

  // No tab, and an unknown tab, both land on the pipeline.
  assert.equal(Console.onboardingStateFromHash('#/platform/onboarding').filters.tab,'pipeline');
  assert.equal(Console.onboardingStateFromHash('#/platform/onboarding?tab=nonsense').filters.tab,'pipeline');
});

test('a link minted before the split still reaches its record',async()=>{
  const Console=await loadConsole();
  // ?application= predates the tab. Landing it on the pipeline would show a
  // page that never renders the application it names.
  const legacy=Console.onboardingStateFromHash('#/platform/onboarding?application=app-1');
  assert.equal(legacy.filters.tab,'applications');
  assert.equal(legacy.application,'app-1');

  const prospect=Console.onboardingStateFromHash('#/platform/onboarding?prospect=firm-1');
  assert.equal(prospect.filters.tab,'pipeline');
  assert.equal(prospect.prospect,'firm-1');

  // An explicit tab still wins over the record's own preference.
  assert.equal(Console.onboardingStateFromHash(
    '#/platform/onboarding?tab=pipeline&application=app-1').filters.tab,'pipeline');
});

test('each sub-module renders alone, and a deep link only fires on its own tab',async()=>{
  const source=await read('app/platform-console.js');
  const renderer=source.slice(source.indexOf('async function renderOnboarding'),
    source.indexOf('function paymentManagedSignupItems'));

  // The queues used to be prepended to the pipeline page for a super admin.
  assert.doesNotMatch(renderer,/insertAdjacentHTML\(\s*'afterbegin'/,
    'the queues must no longer be stacked onto the pipeline page');
  assert.match(renderer,/tab==='signups'/);
  assert.match(renderer,/tab==='applications'\?onboardingStateFromHash/,
    'the application deep link must be scoped to the applications tab');
  assert.match(renderer,/tab==='pipeline'\?onboardingStateFromHash/,
    'the prospect deep link must be scoped to the pipeline tab');
});
