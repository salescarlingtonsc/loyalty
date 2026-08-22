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
  const source=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  const route=source.slice(source.indexOf('async function route(){'),source.indexOf('\n/* ---------- customer wallet ---------- */'));
  /* v184: the console is no longer an eager <script>/<link> in index.html — a customer opening a
     booking page was downloading ~210KB of admin code. The urls live in a JSON manifest that
     app.js fetches on demand for a #/platform route. Both facts are asserted: the manifest is
     present and versioned, and nothing loads the console eagerly. */
  assert.match(source,/<script type="application\/json" id="platformConsoleAssets">/);
  assert.match(source,/"js":"\/platform-console\.js\?v=[0-9a-zA-Z-]+"/);
  assert.match(source,/"css":"\/platform-console\.css\?v=[0-9a-zA-Z-]+"/);
  assert.doesNotMatch(source,/<script src="\/platform-console\.js[^"]*"[^>]*><\/script>/);
  assert.doesNotMatch(source,/<link rel="stylesheet" href="\/platform-console\.css[^"]*">/);
  assert.match(source,/function loadPlatformConsoleAssetsV184\(\)/);
  assert.match(route,/Opening Peekaa admin/);
  assert.match(route,/role="status"/);
  assert.match(route,/const platformRoutePath=String\(h\)\.split\('\?'\)\[0\]\.replace\(\/\\\/\+\$\/,''\)/);
  assert.match(route,/const requestedPlatformRoute=platformRoutePath==='#\/platform'\|\|platformRoutePath\.startsWith\('#\/platform\/'\)/);
  /* V298: the renderer is still awaited inside the route (so a failure lands in this route's own
     catch and replaces the loading card) — it is now awaited into a binding first, because the
     route attaches the caption observer to the console's finished markup before returning. Both
     halves are asserted so the awaiting-not-fire-and-forget contract is strengthened, not weakened. */
  assert.match(route,/await platformConsole\.render\(/);
  assert.match(route,/const platformRenderedV298=await platformConsole\.render\(/);
  assert.match(route,/return platformRenderedV298;/);
});

test('a missing platform module renders a recoverable error instead of falling through',async()=>{
  const source=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  const routeSource=source.slice(
    source.indexOf('async function route(){'),
    source.indexOf('\n/* ---------- customer wallet ---------- */')
  );
  const runMissingModuleRoute=async routeHash=>{
    const rootElement={innerHTML:''};
    const context={
      globalThis:null,document:{documentElement:{setAttribute(){},removeAttribute(){}}},
      root:rootElement,location:{pathname:'/admin',hash:'',search:'',reload(){}},
      history:{replaceState(){}},console:{error(){}},
      beginRouteInvocation:()=>()=>true,
      dashboardRenderEpoch:0,customerWalletRenderEpoch:0,portalRenderEpoch:0,
      destroyMountedTurnstiles(){},disposeCurrentRoute(){},killCharts(){},
      /* V452: route() now closes any open popover on navigation. This harness stubs everything
       that is not a routing decision (see renderPortal/nav/root above); the real function is
       exercised end-to-end in tests/browser/verify-v452-popover-dismiss.mjs step 8. */
      resetPopoverStateV452(){},
      passwordRecoveryError:false,passwordRecoveryActive:false,
      renderRecoveryInvalid(){},renderPasswordUpdate(){},
      entryRouteForLocation:()=>routeHash,
      sb:{auth:{getSession:async()=>({data:{session:{user:{id:'admin-user'}}}})}},
      S:{biz:null,user:null},
      customerRecoveryDisposition:()=>'',customerRecoveryVerified:()=>false,
      rememberCustomerRecoveryVerified(){},
      normalizeCustomerDestination:()=>'',normalizeCustomerBusinessIntent:value=>value,
      businessStaffInviteCodeV151:()=>'',
      /* V345's localhost-only customer preview is consulted before any routing decision; it is
         gated on location.hostname, so off here and in production alike. Without the stub the
         sandbox threw and every case reported the ReferenceError as the platform's own failure. */
      localCustomerPreviewEnabledV345:()=>false,
      /* v185: app/app.js is split by surface at build time. The router resolves which chunk a
         route needs and awaits it; in the sandbox every symbol is already present, so the loader
         is a no-op and the surface decision is exercised for real. */
      appSurfaceRetriedV185:false,
      loadAppChunkV185:async()=>null,
      appSurfaceForRouteV185:(hash,{signedIn=false}={})=>{
        const route=String(hash||'').split('?')[0];
        if(route.startsWith('#/platform'))return null;
        if(['#/b/','#/customer','#/wallet','#/claim','#/join'].some(prefix=>route===prefix.replace(/\/$/,'')||route.startsWith(prefix)))return 'customer';
        if(route==='#/'||route==='')return signedIn?'business':'customer';
        return 'business';
      },
      // v184: the console is fetched on demand. "Missing module" is now a loader that resolves
      // to null — a failed script load takes exactly this path.
      loadPlatformConsoleAssetsV184:async()=>null,
      renderCustomerRegistration(){},renderAuth(){},
      esc:value=>String(value).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;'),
      /* v286: route()'s catch now launders raw error text through ownerErrorText */
      ownerErrorText:error=>String(error?.message||error||''),
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
    assert.match(html,/Peekaa admin could not be loaded/,routeHash);
    assert.doesNotMatch(html,/Workspace unavailable/,routeHash);
  }
});

test('admin async failures remain inside the existing recoverable route boundary',async()=>{
  const source=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
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
