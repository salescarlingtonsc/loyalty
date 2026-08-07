import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../../',import.meta.url);
const app=((await readFile(new URL('app/index.html',root),'utf8'))+'\n'+(await readFile(new URL('app/app.js',root),'utf8')));

const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.notEqual(from,-1,`missing section ${start}`);
  assert.notEqual(to,-1,`missing section boundary ${end}`);
  return app.slice(from,to);
};

test('root is customer-first while the clean business entry resolves staff before onboarding',()=>{
  const routing=section('async function route()','/* ---------- customer wallet ---------- */');
  const customerRoot=routing.indexOf("if(h==='#/'||h==='#/customer'||h==='#/customer/register'");
  const businessEntry=routing.indexOf("if(h==='#/business'){");
  const staffLookup=routing.indexOf("if(!S.biz){\n      const {data:personas,error:personaError}=await sb.rpc('get_my_personas')");
  const onboarding=routing.indexOf('if(!S.biz) return renderOnboard()');

  assert.ok(customerRoot>=0&&customerRoot<businessEntry&&businessEntry<staffLookup&&staffLookup<onboarding,
    'customer and clean business routing must resolve before legacy workspace fallback and onboarding');
  assert.match(routing,/return renderCustomerRegistration\(isRouteCurrent\)/);
  assert.match(routing,/if\(businessPersonaError\)return renderPersonaResolutionUnavailable\(\)/);
  assert.match(routing,/if\(staff\.length>1\)return renderPersonaChoice\(businessPersonas,\{includeCustomer:false\}\)/);
  assert.match(routing,/if\(staff\.length===1\)[\s\S]*nav\(preferredRoute\.startsWith\('#\/workspace\/'\)\?preferredRoute:workspaceRoute\)/);
  assert.match(app,/function renderPersonaChoice\(personas,\{includeCustomer=true\}=\{\}\)[\s\S]*Business workspaces[\s\S]*href="#\/wallet"[\s\S]*BRAND\.customerLabel/);
  assert.match(app,/function renderPersonaResolutionUnavailable\(\)[\s\S]*id="accountAccessRetry"[\s\S]*id="accountAccessSignOut"/);
});

test('an older deferred business-persona route cannot redirect over newer navigation',async()=>{
  const guardSource=app.match(/let routeRenderEpoch=0;[^\n]*\n(?:let [^\n]+\n)*const beginRouteInvocation=\(\)=>\{[\s\S]*?\n\};/)?.[0];
  assert.ok(guardSource,'route generation guard must be defined');
  const {beginRouteInvocation}=new Function(`${guardSource};return {beginRouteInvocation};`)();
  let releaseOlder;
  const olderResponse=new Promise(resolve=>{releaseOlder=resolve});
  const olderRoute=(async()=>{
    const isRouteCurrent=beginRouteInvocation();
    await olderResponse;
    return isRouteCurrent();
  })();
  const isNewerRouteCurrent=beginRouteInvocation();
  releaseOlder();
  assert.equal(await olderRoute,false,'older route must become stale after newer navigation begins');
  assert.equal(isNewerRouteCurrent(),true,'newer route must remain current');

  const routing=section('async function route()','/* ---------- customer wallet ---------- */');
  assert.match(routing,/const isRouteCurrent=beginRouteInvocation\(\)/);
  assert.match(routing,/const \{data:businessPersonas,error:businessPersonaError\}=await sb\.rpc\('get_my_personas'\);\n      if\(!isRouteCurrent\(\)\)return;/);
});

test('390px navigation uses a bounded persistent dock and a discoverable module drawer',()=>{
  const responsive=section('@media(max-width:960px)','@media(max-width:767px)');
  assert.match(responsive,/\.side\{display:none\}/);
  assert.match(responsive,/\.staff-mobile-dock\{[^}]*position:fixed[^}]*left:0[^}]*right:0[^}]*bottom:0[^}]*display:grid/s);
  assert.match(responsive,/grid-template-columns:repeat\(var\(--staff-mobile-count,4\),minmax\(0,1fr\)\)/);
  assert.match(app,/\.staff-mobile-drawer\{[^}]*width:min\(330px,calc\(100vw - 24px\)\)[^}]*overflow:auto/s);
  assert.match(app,/function staffMobileActionsHtml\(page\)[\s\S]*navHtml\(page,'mobile-nav'\)/);
  assert.doesNotMatch(responsive,/overflow-x:auto|flex:0 0 max-content/);
});

test('Turnstile controls are destroyed before route and direct-render replacement',()=>{
  const turnstile=section('const mountedTurnstileControls=new Set()','/* Supabase Auth has CAPTCHA protection enabled');
  const route=section('async function route()','/* ---------- customer wallet ---------- */');
  const auth=section("function renderAuth(mode='in',{admin=false}={})",'function validNewPassword');
  const registration=section('function customerRegistrationShell(body)','function renderCustomerOtpVerification');
  const portal=section('async function renderPortal(slug)','async function boot()');

  assert.match(turnstile,/const destroy=\(\)=>\{[\s\S]*destroyed=true[\s\S]*retryEl\.onclick=null[\s\S]*removeWidget\(\)/);
  assert.match(turnstile,/return control/);
  assert.match(route,/customerWalletRenderEpoch\+=1;\n  portalRenderEpoch\+=1;\n  destroyMountedTurnstiles\(\)/);
  assert.match(auth,/destroyMountedTurnstiles\(\)/);
  assert.match(registration,/destroyMountedTurnstiles\(\)/);
  assert.match(portal,/const draw=\(\)=>\{\n    destroyMountedTurnstiles\(\)/);
  // V206: the plain `destroyed` check after the async loadTurnstile() await was replaced by a
  // per-render generation guard (`live()`) — a widget torn down and re-rendered mid-flight must
  // not have the STALE attempt's post-await continuation touch the DOM or the current token.
  assert.match(turnstile,/const live=\(\)=>!destroyed&&mine===generation;/);
  assert.match(turnstile,/if\(!live\(\)\|\|!document\.getElementById\(container\)\)\{stopStall\(\);return\}/);
  assert.match(turnstile,/if\(!live\(\)\)\{stopStall\(\);return\}/);
  // destroy() bumps the generation so any in-flight render's callbacks are ignored, and stops
  // the stall watchdog so a destroyed widget cannot fire a Retry-prompting timeout later.
  assert.match(turnstile,/const destroy=\(\)=>\{\n\s*if\(destroyed\)return;\n\s*destroyed=true;generation\+=1;stopStall\(\);/);
});
