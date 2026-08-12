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

test('desktop administration has six primary task areas plus secondary platform controls without removing routes',async()=>{
  const Console=await loadConsole();
  const access=Console.normalizePlatformAccess({
    role:'super_admin',scope:'all',module_perms:{}
  });
  const allowed=Console.visibleRoutes(access);
  const groups=Console.platformNavigationGroups(allowed);
  assert.deepEqual(
    Array.from(groups,group=>({
      key:group.key,
      routes:Array.from(group.routes,route=>route.key)
    })),
    [
      {key:'overview',routes:['overview']},
      {key:'sales',routes:['onboarding','crm','demo-requests']}, // V292
      {key:'customers',routes:['customer-lifecycle','firms','companies']},
      {key:'reports',routes:['reports','marketing']}, // V256
      {key:'finance',routes:['subscription-operations','billing','pnl','commissions']},
      {key:'automation',routes:['automation']},
      {key:'platform-controls',routes:['sectors','partners','access']}
    ]
  );
  assert.equal(groups.filter(group=>!group.secondary).length,6);
  assert.equal(groups.find(group=>group.key==='platform-controls')?.secondary,true);
  assert.deepEqual(
    Array.from(allowed,route=>route.key),
    ['overview','onboarding','crm','demo-requests','customer-lifecycle','firms','companies','reports','marketing','billing','subscription-operations','pnl','commissions','sectors','automation','partners','access'], // V282
    'streamlining must not delete a capability or deep link'
  );
});

test('restricted platform roles only see task groups containing authorised routes',async()=>{
  const Console=await loadConsole();
  const access=Console.normalizePlatformAccess({
    role:'sales_staff',scope:'own_created_or_assigned',
    module_perms:{overview:'r',onboarding:'rw',firms:'r',reports:'r'}
  });
  const groups=Console.platformNavigationGroups(Console.visibleRoutes(access));
  assert.deepEqual(
    Array.from(groups,group=>Array.from(group.routes,route=>route.key)),
    [['overview'],['onboarding','crm'],['firms'],['reports']]
  );
});

test('desktop task groups keep a one-click default and progressively disclose secondary routes',async()=>{
  const [source,styles]=await Promise.all([
    read('app/platform-console.js'),read('app/platform-console.css')
  ]);
  assert.match(source,/class="platform-nav-group"/);
  assert.match(source,/class="platform-nav-group-home"/);
  assert.match(source,/data-platform-nav-toggle/);
  assert.match(source,/class="platform-nav-group-items"/);
  assert.match(source,/homeRoute\.hash/);
  assert.match(source,/aria-expanded=/);
  assert.match(source,/items\.hidden=!expanded/);
  assert.match(source,/aria-current="page"/);
  assert.match(styles,/\.platform-nav-group-home/);
  assert.match(styles,/\.platform-nav-group-items/);
  assert.match(styles,/\.platform-nav-secondary/);
});

test('duplicate workspace action is hidden on desktop but remains available when the rail is absent',async()=>{
  const [source,styles]=await Promise.all([
    read('app/platform-console.js'),read('app/platform-console.css')
  ]);
  assert.match(source,/class="btn ghost sm platform-topbar-workspace"/);
  assert.match(styles,/@media\(min-width:761px\)\{\.platform-topbar-workspace\{display:none\}\}/);
  assert.match(styles,/@media\(max-width:760px\)[\s\S]*\.platform-rail\{display:none\}/);
});

test('firm directory uses the firm name as the single open action',async()=>{
  const source=await read('app/platform-console.js');
  const rows=source.slice(
    source.indexOf('function enterpriseFirmRows'),
    source.indexOf('function enterpriseBranchOptions')
  );
  assert.equal((rows.match(/data-enterprise-firm=/g)||[]).length,1);
  assert.doesNotMatch(rows,/>Open</);
  assert.match(source,/headers:\['Firm \/ UEN','Sector','Owner','Contact','Branches','Customers','Net revenue','Returning','Transactions'\]/);
});

test('task-first overview keeps authoritative exception types and deep links',async()=>{
  const Console=await loadConsole(),now=Date.now();
  const items=Console.buildPlatformTodayQueue({
    prospects:[{
      prospect_id:'prospect-1',company_name:'Blocked firm',stage:'onboarding',
      onboarding_status:'blocked',created_at:new Date(now-86_400_000).toISOString()
    }],
    billing:[{
      business_id:'business-1',business_name:'Past-due firm',
      payment_status:'past_due',days_past_due:3,due_at:new Date(now-(3*86_400_000)).toISOString()
    }],
    commissions:[{
      accrual_id:'commission-1',consultant_name:'Consultant One',
      status:'payable',due_at:new Date(now-86_400_000).toISOString()
    }]
  });
  assert.deepEqual(
    Array.from(items,item=>[item.type,item.primaryAction.href]),
    [
      ['prospect','#/platform/onboarding?prospect=prospect-1'],
      ['billing','#/platform/billing?business=business-1'],
      ['commission','#/platform/commissions?accrual=commission-1']
    ]
  );
  const source=await read('app/platform-console.js');
  assert.match(source,/Partial platform data/);
  assert.match(source,/Available areas remain live below/);
});
