import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../../',import.meta.url);
const app=await readFile(new URL('app/index.html',root),'utf8');

const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.notEqual(from,-1,`missing section ${start}`);
  assert.notEqual(to,-1,`missing section boundary ${end}`);
  return app.slice(from,to);
};

test('authenticated root resolves customer-only and dual-role personas before merchant onboarding',()=>{
  const routing=section('async function route()','/* ---------- customer wallet ---------- */');
  const rootPersona=routing.indexOf("if(h==='#/'){\n      const {data:rootPersonas,error:rootPersonaError}=await sb.rpc('get_my_personas')");
  const staffLookup=routing.indexOf("if(!S.biz){\n      const {data:st}=await sb.from('staff')");
  const onboarding=routing.indexOf('if(!S.biz) return renderOnboard()');

  assert.ok(rootPersona>=0&&rootPersona<staffLookup&&staffLookup<onboarding,
    'persona routing must run before the legacy staff lookup and merchant onboarding');
  assert.match(routing,/if\(rootPersonaError\)return renderPersonaResolutionUnavailable\(\)/);
  assert.match(routing,/customerPersonas\.length&&!staffPersonas\.length\)\{nav\('#\/wallet'\);return\}/);
  assert.match(routing,/customerPersonas\.length&&staffPersonas\.length\)\{nav\(rootPersonas\.default_route/);
  assert.match(app,/function renderPersonaResolutionUnavailable\(\)[\s\S]*id="accountAccessRetry"[\s\S]*id="accountAccessSignOut"/);
});

test('an older deferred root-persona route cannot redirect over newer navigation',async()=>{
  const guardSource=app.match(/let routeRenderEpoch=0;[^\n]*\nconst beginRouteInvocation=\(\)=>\{[\s\S]*?\n\};/)?.[0];
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
  assert.match(routing,/await sb\.rpc\('get_my_personas'\);\n      if\(!isRouteCurrent\(\)\|\|location\.hash&&location\.hash!=='#\/'\)return;/);
});

test('390px navigation is a bounded discoverable grid without horizontal overflow',()=>{
  const responsive=section('@media(max-width:960px)','@media(max-width:767px)');
  assert.match(responsive,/\.side\{[^}]*max-width:100vw[^}]*overflow:visible/s);
  assert.match(responsive,/\.nav\{[^}]*display:grid[^}]*grid-template-columns:repeat\(2,minmax\(0,1fr\)\)[^}]*width:100%/s);
  assert.match(responsive,/\.nav>a,\.navgroup\{min-width:0\}/);
  assert.match(responsive,/\.nav a,\.navhead\{[^}]*width:100%[^}]*white-space:normal/s);
  assert.doesNotMatch(responsive,/overflow-x:auto|flex:0 0 max-content/);
});

test('Turnstile controls are destroyed before route and direct-render replacement',()=>{
  const turnstile=section('const mountedTurnstileControls=new Set()','/* Supabase Auth has CAPTCHA protection enabled');
  const route=section('async function route()','/* ---------- customer wallet ---------- */');
  const auth=section("function renderAuth(mode='in')",'function validNewPassword');
  const registration=section('function customerRegistrationShell(body)','function renderCustomerOtpVerification');
  const portal=section('async function renderPortal(slug)','async function boot()');

  assert.match(turnstile,/const destroy=\(\)=>\{[\s\S]*destroyed=true[\s\S]*retryEl\.onclick=null[\s\S]*removeWidget\(\)/);
  assert.match(turnstile,/return control/);
  assert.match(route,/customerWalletRenderEpoch\+=1;\n  destroyMountedTurnstiles\(\)/);
  assert.match(auth,/destroyMountedTurnstiles\(\)/);
  assert.match(registration,/destroyMountedTurnstiles\(\)/);
  assert.match(portal,/const draw=\(\)=>\{\n    destroyMountedTurnstiles\(\)/);
  assert.match(turnstile,/if\(destroyed\|\|!document\.getElementById\(container\)\) return/);
});
