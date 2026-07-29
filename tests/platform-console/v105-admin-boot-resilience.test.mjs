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

test('localized platform UI works with the real frozen helper contract',async()=>{
  const Console=await loadConsole();
  const calls=[];
  const frozenCUI=Object.freeze({
    icon(name,options){calls.push(['icon',this,name,options]);return `<i>${name}</i>`},
    pageHeader(options){calls.push(['pageHeader',this,options]);return options.title},
    focusRoute(){calls.push(['focusRoute',this])}
  });
  const localized=Console.localizedPlatformCUI(frozenCUI);
  assert.equal(localized.icon('home',{size:19}),'<i>home</i>');
  assert.equal(localized.pageHeader({title:'Overview'}),'Overview');
  localized.focusRoute();
  assert.equal(calls.length,3);
  assert.ok(calls.every(([,receiver])=>receiver===frozenCUI),'facade methods retain the original helper receiver');
});

test('admin route exposes a loading state and awaits the async platform renderer',async()=>{
  const source=await read('app/index.html');
  const route=source.slice(source.indexOf('async function route(){'),source.indexOf('\n/* ---------- customer wallet ---------- */'));
  assert.match(source,/<link rel="stylesheet" href="\/platform-console\.css\?v=20260729-v105">/);
  assert.match(source,/<script src="\/platform-console\.js\?v=20260729-v105"><\/script>/);
  assert.match(route,/Opening Nestly admin/);
  assert.match(route,/role="status"/);
  assert.match(route,/const platformRoutePath=String\(h\)\.split\('\?'\)\[0\]\.replace\(\/\\\/\+\$\/,''\)/);
  assert.match(route,/const requestedPlatformRoute=platformRoutePath==='#\/platform'\|\|platformRoutePath\.startsWith\('#\/platform\/'\)/);
  assert.match(route,/return await platformConsole\.render\(/);
});

test('a missing platform module renders a recoverable error instead of falling through',async()=>{
  const source=await read('app/index.html');
  const routeSource=source.slice(
    source.indexOf('async function route(){'),
    source.indexOf('\n/* ---------- customer wallet ---------- */')
  );
  const runMissingModuleRoute=async routeHash=>{
    const rootElement={innerHTML:''};
    const context={
      globalThis:null,document:{documentElement:{setAttribute(){}}},
      root:rootElement,location:{pathname:'/admin',hash:'',search:'',reload(){}},
      history:{replaceState(){}},console:{error(){}},
      beginRouteInvocation:()=>()=>true,
      dashboardRenderEpoch:0,customerWalletRenderEpoch:0,portalRenderEpoch:0,
      destroyMountedTurnstiles(){},disposeCurrentRoute(){},killCharts(){},
      passwordRecoveryError:false,passwordRecoveryActive:false,
      renderRecoveryInvalid(){},renderPasswordUpdate(){},
      entryRouteForLocation:()=>routeHash,
      sb:{auth:{getSession:async()=>({data:{session:{user:{id:'admin-user'}}}})}},
      S:{biz:null,user:null},
      customerRecoveryDisposition:()=>'',customerRecoveryVerified:()=>false,
      rememberCustomerRecoveryVerified(){},
      normalizeCustomerDestination:()=>'',normalizeCustomerBusinessIntent:value=>value,
      renderCustomerRegistration(){},renderAuth(){},
      esc:value=>String(value).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;'),
      $:id=>id==='routeReload'?{onclick:null}:null
    };
    context.globalThis=context;
    vm.runInNewContext(`${routeSource}\nthis.route=route;`,context,{filename:'admin-route-harness.js'});
    await context.route();
    return rootElement.innerHTML;
  };
  for(const routeHash of ['#/platform','#/platform?view=attention','#/platform/firms?view=won']){
    const html=await runMissingModuleRoute(routeHash);
    assert.match(html,/Something went wrong/,routeHash);
    assert.match(html,/Nestly admin could not be loaded/,routeHash);
    assert.doesNotMatch(html,/Workspace unavailable/,routeHash);
  }
});

test('admin async failures remain inside the existing recoverable route boundary',async()=>{
  const source=await read('app/index.html');
  const route=source.slice(source.indexOf('async function route(){'),source.indexOf('\n/* ---------- customer wallet ---------- */'));
  assert.match(route,/try\{/);
  assert.match(route,/catch\(e\)\{/);
  assert.match(route,/Something went wrong/);
  assert.match(route,/id="routeReload"/);
});

test('platform access states expose only actions that can actually resolve the state',async()=>{
  const source=await read('app/platform-console.js');
  const denied=source.slice(
    source.indexOf('function platformAccessDeniedHtml'),
    source.indexOf('function platformAccessLoadFailureHtml')
  );
  const outage=source.slice(
    source.indexOf('function platformAccessLoadFailureHtml'),
    source.indexOf('function isPlatformAccessDeniedError')
  );

  assert.doesNotMatch(denied,/CUI\.errorState/,
    'a genuinely denied account must not receive a dead generic retry action');
  assert.match(denied,/Back to workspace/);
  assert.match(denied,/platformDeniedSignOut/);
  assert.match(outage,/retryId:'platformAccessRetry'/);
  assert.equal((outage.match(/id="platformAccessRetry"/g)||[]).length,0,
    'the outage recovery uses the single retry rendered by errorState');
  assert.match(outage,/Your access has not been removed/);
});
