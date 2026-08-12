/* GENERATED FILE — do not edit.
   The shared core of app/app.js, split by scripts/quality/split-app-bundle.mjs.
   Edit app/app.js and run: npm run bundle-stamp */
/* Peekaa application script — extracted from index.html (startup split phase 2).
   Served same-origin, revalidated per load (ETag), cached by the service worker
   under CACHE_VERSION. Execution order: classic blocking deps in <head> run at
   parse; the deferred page bundles run in document order; this file runs last
   among the deferred scripts and boots on DOMContentLoaded. */

/* ============ Peekaa app (legacy runtime/API identifiers remain compatible) ============ */
const RUNTIME_CONFIG=(()=>{try{return window.FrenlyRuntimeConfig.require(window)}catch{
  window.FrenlyRuntimeConfig?.renderFailure(document.getElementById('root'));
  throw new Error('Peekaa runtime configuration is unavailable.');
}})();
const CUI=window.FrenlyCustomerUI;
const BRAND=window.NestlyBrand;
const SB_URL=RUNTIME_CONFIG.supabaseUrl;
const SB_KEY=RUNTIME_CONFIG.supabasePublishableKey;
/* Preconnect to the API origin as early as the runtime config allows — the
   origin is configuration, so it must not be hardcoded in markup. */
try{const pc=document.createElement('link');pc.rel='preconnect';pc.href=SB_URL;document.head.appendChild(pc)}catch{}
function warmRuntimeOrigin(origin){
  const url=new URL(origin);
  const preconnect=document.createElement('link');preconnect.rel='preconnect';preconnect.href=url.origin;preconnect.crossOrigin='anonymous';
  const dns=document.createElement('link');dns.rel='dns-prefetch';dns.href=`//${url.host}`;
  document.head.append(preconnect,dns);
}
warmRuntimeOrigin(SB_URL);
const optionalLibraryLoads=new Map();
function loadOptionalLibrary({key,src,integrity,ready}){
  if(ready())return Promise.resolve();
  if(optionalLibraryLoads.has(key))return optionalLibraryLoads.get(key);
  const promise=new Promise((resolve,reject)=>{
    const script=document.createElement('script');script.src=src;script.async=true;script.crossOrigin='anonymous';
    if(integrity)script.integrity=integrity;
    script.onload=()=>ready()?resolve():reject(new Error(`${key} did not initialise.`));
    script.onerror=()=>reject(new Error(`${key} could not be loaded.`));
    document.head.appendChild(script);
  }).catch(error=>{optionalLibraryLoads.delete(key);throw error});
  optionalLibraryLoads.set(key,promise);return promise;
}
const loadQrLibrary=()=>loadOptionalLibrary({key:'qr-code',src:'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js',integrity:'sha384-3zSEDfvllQohrq0PHL1fOXJuC/jSOO34H46t6UQfobFOmxE5BpjjaIJY5F2/bMnU',ready:()=>typeof globalThis.QRCode==='function'});
const loadScannerLibrary=()=>loadOptionalLibrary({key:'qr-scanner',src:'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js',integrity:'sha384-b5Ya4Bq3qCyz39m2ISh+4DxjAIljdeFwK/BsXLuj9gugaNwAcj/ia15fxNZL9Nlx',ready:()=>typeof globalThis.jsQR==='function'});
const loadSpreadsheetLibrary=()=>loadOptionalLibrary({key:'spreadsheet-import',src:'https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js',integrity:'sha384-EnyY0/GSHQGSxSgMwaIPzSESbqoOLSexfnSMN2AP+39Ckmn92stwABZynq1JyzdT',ready:()=>typeof globalThis.XLSX==='object'});
const publicAppUrl=(route='')=>window.NestlyNativeBridge.publicUrl(`/#/${String(route).replace(/^#?\/?/,'')}`);
/* detectSessionInUrl:false — with it left at its (true) default, supabase-js inspects
   window.location.hash on load and can history.replaceState the hash away on a hash-routed
   SPA, which is why a browser refresh was silently losing the current route ("refresh does
   nothing unless I retype the URL"). We don't use Supabase's own hash-based OAuth redirect
   flow here, so it's safe to turn off. */
const sb=window.supabase.createClient(SB_URL,SB_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false,flowType:'implicit',
  experimental:{passkey:true}}});
/* V208: keep the EDGE FUNCTION bearer token in step with the signed-in user.
   A real branch purchase failed in production with a bare 401 from stripe-billing-command, and
   the function's own auth step reported auth_token_rejected: the bearer it received was the
   publishable key, not the user's access token. This project uses the new publishable key
   format, which is not a JWT, so the server had nothing to identify a user with and every edge
   function that reads auth.uid() would refuse. Billing surfaced it first only because it is the
   one a customer pays for. Re-pointing functions at the live session on every auth change fixes
   all of them at once, without touching a single call site. */
/* (The key-format name is spelled out in the commit message rather than here: this file is
   scanned for hardcoded credentials and the literal prefix trips that scanner.) */
const syncEdgeFunctionAuthV208=session=>{
  try{sb.functions.setAuth(session?.access_token||SB_KEY)}catch(error){}
};
sb.auth.onAuthStateChange((_event,session)=>syncEdgeFunctionAuthV208(session));
sb.auth.getSession().then(({data})=>syncEdgeFunctionAuthV208(data?.session)).catch(()=>{});
/* v177 client error reporting. Before this the app had no client-side error visibility at all:
   a customer hitting a broken render simply saw a blank card and nobody ever knew. Sends to
   report_client_error_v177 (anon + authenticated, capped, deduped and non-raising server-side).
   The browser adds its own guards — 5 reports per page load and one report per distinct message
   per session — so a looping component cannot spend the server's hourly flood budget. Every
   failure here is swallowed: a reporter that throws would break the page it is reporting on. */
const CLIENT_ERROR_REPORT_LIMIT=5;
let clientErrorReportCount=0;
const clientErrorReportSeen=new Set();
/* Noise that is never actionable: the benign ResizeObserver notification, cross-origin script
   errors that arrive with no stack at all, and aborts (which are our own timeouts/navigations). */
const clientErrorIsNoise=(message,stack)=>message.includes('ResizeObserver loop')
  ||(message.includes('Script error.')&&!stack)
  ||message.includes('AbortError')||stack.includes('AbortError')
  ||message.includes('signal is aborted')||message.includes('The operation was aborted');
function clientErrorSurface(){
  const hash=String(globalThis.location?.hash||'');
  if(hash.startsWith('#/business')||hash.startsWith('#/platform')||hash.startsWith('#/workspace'))return 'business';
  try{if(typeof S!=='undefined'&&S?.user)return 'customer'}catch{}
  return 'public';
}
function reportClientError(event){
  try{
    if(clientErrorReportCount>=CLIENT_ERROR_REPORT_LIMIT)return;
    const reason=event?.reason;
    const message=String(event?.message||reason?.message||reason||'unknown').slice(0,500).trim();
    const stack=String(event?.error?.stack||reason?.stack||'').slice(0,2000);
    if(!message||clientErrorIsNoise(message,stack))return;
    if(clientErrorReportSeen.has(message))return;
    clientErrorReportSeen.add(message);clientErrorReportCount++;
    let build='';try{build=String(buildIdentity?.shortSha||'')}catch{build=''}
    Promise.resolve(sb.rpc('report_client_error_v177',{
      p_surface:clientErrorSurface(),p_message:message,p_stack:stack,
      p_url:String(globalThis.location?.href||'').slice(0,300),p_build:build
    })).catch(()=>{});
  }catch{}
}
window.addEventListener('error',reportClientError);
window.addEventListener('unhandledrejection',reportClientError);
/* v177 customer RPC timeout. A PostgREST call with no client deadline can hang until the browser
   gives up, leaving a customer-facing skeleton spinning forever with no retry affordance. Every
   customer read below goes through this helper, which aborts at `ms` and normalises the outcome
   into the same {data,error} shape the call sites already destructure, so an abort surfaces
   through the EXISTING error branches (walletSectionError / renderCustomerWalletRetry) and the
   customer gets the normal Retry button instead of an eternal spinner. */
const customerRpcSignal=ms=>{
  try{if(typeof AbortSignal?.timeout==='function')return AbortSignal.timeout(ms)}catch{}
  const controller=new AbortController();
  setTimeout(()=>{try{controller.abort()}catch{}},ms);
  return controller.signal;
};
const customerRpc=(name,args,ms=12000)=>sb.rpc(name,args).abortSignal(customerRpcSignal(ms))
  .then(result=>result,error=>({data:null,error:{code:'timeout',
    message:`This is taking too long. ${String(error?.message||error||'Request timed out.')}`}}));
let buildIdentity=Object.freeze({available:false});
const buildIdentityLabel=()=>buildIdentity.available
  ?`Build ${buildIdentity.shortSha} · ${buildIdentity.environment}`:'Build identity unavailable';
const buildIdentityHtml=()=>`<span class="build-identity" data-build-identity>${esc(buildIdentityLabel())}</span>`;
function syncBuildIdentityLabels(){document.querySelectorAll('[data-build-identity]').forEach(element=>{element.textContent=buildIdentityLabel()})}
async function loadBuildIdentity(){
  try{
    const response=await fetch('/api/build',{method:'GET',credentials:'same-origin',headers:{accept:'application/json'}});
    const payload=await response.json();
    const valid=response.ok&&payload?.schemaVersion===1&&payload?.service==='loyalty'&&payload?.available===true
      &&/^[0-9a-f]{40}$/.test(payload.commitSha)&&payload.shortSha===payload.commitSha.slice(0,12)
      &&['production','preview','development'].includes(payload.environment);
    if(!valid)throw new Error('Build identity unavailable.');
    buildIdentity=Object.freeze({available:true,commitSha:payload.commitSha,shortSha:payload.shortSha,environment:payload.environment});
    window.__FRENLY_BUILD_IDENTITY__=buildIdentity;
  }catch{buildIdentity=Object.freeze({available:false})}
  syncBuildIdentityLabels();
}
const legalLinks=(locale='en')=>{
  const copy={
    en:{label:'Legal and privacy',privacy:'Privacy',terms:'Terms',data:'Data request'},
    'zh-CN':{label:'法律与隐私',privacy:'隐私政策',terms:'条款',data:'数据请求'},
    ms:{label:'Undang-undang dan privasi',privacy:'Privasi',terms:'Terma',data:'Permintaan data'}
  }[locale]||{label:'Legal and privacy',privacy:'Privacy',terms:'Terms',data:'Data request'};
  return `<nav class="legal-links" aria-label="${esc(copy.label)}"><a href="/privacy.html">${esc(copy.privacy)}</a><a href="/terms.html">${esc(copy.terms)}</a><a href="/data-request.html">${esc(copy.data)}</a>${buildIdentityHtml()}</nav>`;
};
const publicFunctionUrl=(name,query='')=>`${SB_URL}/functions/v1/${name}${query}`;
function publicGatewayHeaders(body,accessToken=''){
  const headers={};
  if(body)headers['content-type']='application/json';
  const token=String(accessToken||'').trim();
  if(token)headers.Authorization=`Bearer ${token}`;
  return Object.keys(headers).length?headers:undefined;
}
async function publicGateway(name,{method='POST',body=null,query='',accessToken='',signal}={}){
  const response=await fetch(publicFunctionUrl(name,query),{
    method,headers:publicGatewayHeaders(body,accessToken),
    body:body?JSON.stringify(body):undefined,credentials:'omit',signal});
  let payload=null;
  try{payload=await response.json()}catch{}
  if(!response.ok) throw new Error(payload?.error||'We could not process that request.');
  return payload;
}
let turnstileLoader;
const mountedTurnstileControls=new Set();
function destroyMountedTurnstiles(){
  [...mountedTurnstileControls].forEach(control=>control.destroy());
}
/* V206: Turnstile must never be able to strand the sign-in form.
   Two failure shapes were reaching users on iPadOS/WebKit:
   (1) the api.js request hangs with NEITHER onload NOR onerror — a content blocker, a captive
       portal, or a stalled TLS handshake to challenges.cloudflare.com. The promise never settled,
       so `await loadTurnstile()` never returned, the status stayed on "Loading security check…"
       with the Retry button hidden, and Sign in stayed disabled forever.
   (2) the loader promise was CACHED after it rejected, so once the first attempt failed every
       later Retry re-awaited the same rejected promise and could never recover.
   Both are fixed here: a hard deadline settles the promise, and every failure path drops the
   cached promise so a Retry genuinely re-requests the script. */
const TURNSTILE_SCRIPT_TIMEOUT_MS=8000;
/* How long a rendered widget may sit with no callback of any kind before the UI declares it
   wedged. Cloudflare's own interactive flows can legitimately take a while once the checkbox is
   SHOWN, which is why the stall timer is disarmed the moment before-interactive fires. */
const TURNSTILE_SOLVE_TIMEOUT_MS=20000;
/* V286: every primary button on an auth screen is disabled until Turnstile hands back a
   token. When the widget is merely slow — not wedged, so none of the error callbacks fire —
   the screen offers no way out for 20s. This is the shorter, honest line: after 12s without a
   token the user is told the one thing that actually helps. It never re-enables a button and
   never bypasses the check. */
const TURNSTILE_SLOW_FALLBACK_MS_V286=12000;
const turnstileApiReady=()=>(window.turnstile&&typeof window.turnstile.render==='function')?window.turnstile:null;
function loadTurnstile(){
  const ready=turnstileApiReady();
  if(ready) return Promise.resolve(ready);
  if(turnstileLoader) return turnstileLoader;
  turnstileLoader=new Promise((resolve,reject)=>{
    const script=document.createElement('script');
    script.src='https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
    script.async=true;script.defer=true;
    let settled=false;
    const fail=(message,{remove=true}={})=>{
      if(settled)return;
      settled=true;clearTimeout(deadline);turnstileLoader=null;
      if(remove)script.remove();
      reject(new Error(message));
    };
    const succeed=()=>{
      if(settled)return;
      const api=turnstileApiReady();
      /* onload fired but the global is absent: the response was not the real api.js (a captive
         portal or an interception proxy). Treat it as a load failure, not as success. */
      if(!api)return fail('Security check unavailable.');
      settled=true;clearTimeout(deadline);resolve(api);
    };
    /* The script element is deliberately LEFT in place on timeout: a slow-but-alive request may
       still define window.turnstile, and the next Retry then resolves instantly from the global. */
    const deadline=setTimeout(()=>fail('Security check timed out.',{remove:false}),TURNSTILE_SCRIPT_TIMEOUT_MS);
    script.onload=succeed;
    script.onerror=()=>fail('Security check unavailable.');
    document.head.appendChild(script);
  });
  return turnstileLoader;
}
const authSecurityCopy=(locale,key)=>{
  const copy={
    en:{
      loading:'Loading security check…',retry:'Retry security check',complete:'Security check complete.',
      expired:'Security check expired. Please try again.',timeout:'Security check timed out. Please try again.',
      connect:'Security check could not connect. Please retry, or check your browser and network settings.',
      load:'Security check could not load. Check your connection and try again.',
      continue:'Complete the security check to continue.',
      slowFallback:'Taking long? Reload to retry.',
      interactive:'Tick “Verify you are human” above to continue.',
      showPassword:'Show password',hidePassword:'Hide password',
      passkey:'Sign in with Face ID, Touch ID or passkey',passkeyTitle:'Use Face ID, Touch ID or passkey'
    },
    'zh-CN':{
      loading:'正在加载安全验证…',retry:'重试安全验证',complete:'安全验证已完成。',
      expired:'安全验证已过期，请重试。',timeout:'安全验证超时，请重试。',
      connect:'无法连接安全验证。请重试，或检查浏览器及网络设置。',
      load:'无法加载安全验证。请检查网络连接后重试。',
      continue:'请完成安全验证以继续。',
      slowFallback:'时间过长？请重新加载页面重试。',
      interactive:'请勾选上方的“确认您是真人”以继续。',
      showPassword:'显示密码',hidePassword:'隐藏密码',
      passkey:'使用面容 ID、触控 ID 或通行密钥登录',passkeyTitle:'使用面容 ID、触控 ID 或通行密钥'
    },
    ms:{
      loading:'Memuatkan semakan keselamatan…',retry:'Cuba semakan keselamatan lagi',complete:'Semakan keselamatan selesai.',
      expired:'Semakan keselamatan telah tamat tempoh. Sila cuba lagi.',timeout:'Semakan keselamatan telah tamat masa. Sila cuba lagi.',
      connect:'Semakan keselamatan tidak dapat disambungkan. Cuba lagi atau semak tetapan pelayar dan rangkaian anda.',
      load:'Semakan keselamatan tidak dapat dimuatkan. Semak sambungan anda dan cuba lagi.',
      continue:'Lengkapkan semakan keselamatan untuk meneruskan.',
      slowFallback:'Mengambil masa lama? Muat semula untuk mencuba lagi.',
      interactive:'Tandakan “Verify you are human” di atas untuk meneruskan.',
      showPassword:'Tunjukkan kata laluan',hidePassword:'Sembunyikan kata laluan',
      passkey:'Log masuk dengan Face ID, Touch ID atau kunci laluan',passkeyTitle:'Gunakan Face ID, Touch ID atau kunci laluan'
    }
  };
  return copy[locale]?.[key]||copy.en[key]||key;
};
async function mountTurnstile(siteKey,{container,status,retry,action,onToken,locale='en'}){
  const statusEl=$(status),retryEl=$(retry);let api,widgetId,destroyed=false;
  const security=key=>authSecurityCopy(locale,key);
  let tokenSeenV286=false;
  const slowNoteV286=document.createElement('p');
  slowNoteV286.className='challenge-status';
  slowNoteV286.id=`${status}-slow-note`;
  slowNoteV286.hidden=true;
  slowNoteV286.textContent=security('slowFallback');
  statusEl.insertAdjacentElement('afterend',slowNoteV286);
  const slowTimerV286=setTimeout(()=>{
    if(destroyed||tokenSeenV286)return;
    slowNoteV286.hidden=false;
  },TURNSTILE_SLOW_FALLBACK_MS_V286);
  const stopSlowNoteV286=()=>{clearTimeout(slowTimerV286);slowNoteV286.hidden=true};
  /* A passed check should be invisible: red status text and a "Retry" link after
     success read as failure. The block only surfaces while loading or on error. */
  const setPassed=passed=>{
    statusEl.hidden=passed;
    const host=document.getElementById(container);
    if(host)host.style.display=passed?'none':'';
    statusEl.closest('.challenge')?.classList.toggle('challenge-passed',passed);
  };
  const message=(text,isError=false)=>{setPassed(false);statusEl.textContent=text;statusEl.style.color=isError?'#C0392B':''};
  const clear=(text,isError=false)=>{onToken('');message(text,isError)};
  const logTurnstileError=(errorCode)=>{
    const code=String(errorCode||'unknown').replace(/[^\w.-]/g,'').slice(0,64)||'unknown';
    console.warn('Turnstile error code:',code);
  };
  const removeWidget=()=>{
    const host=document.getElementById(container);
    if(api&&widgetId!==undefined&&host){
      try{if(typeof api.remove==='function')api.remove(widgetId);else api.reset(widgetId)}catch{}
    }
    widgetId=undefined;
    host?.replaceChildren();
  };
  /* Every render attempt gets a generation. A widget torn down by a Retry (or by a re-render of
     the screen) can still invoke its callbacks afterwards on WebKit; without this, a stale
     challenge could write its token into the CURRENT form — or blank a token the user had
     already earned. A callback from an older generation is ignored outright. */
  let generation=0;
  let stall=null;
  const stopStall=()=>{clearTimeout(stall);stall=null};
  /* The widget rendered but nothing came back: no token, no checkbox prompt, no error callback.
     Turnstile has no client-side guarantee that any of its callbacks ever fire, so this is the
     backstop that converts "silently wedged" into an actionable failure with a Retry. */
  const armStall=(mine)=>{
    stopStall();
    stall=setTimeout(()=>{
      if(destroyed||mine!==generation)return;
      clear(security('timeout'),true);retryEl.hidden=false;
    },TURNSTILE_SOLVE_TIMEOUT_MS);
  };
  const render=async()=>{
    if(destroyed)return;
    generation+=1;
    const mine=generation;
    const live=()=>!destroyed&&mine===generation;
    message(security('loading'));retryEl.hidden=true;
    armStall(mine);
    try{
      api=await loadTurnstile();
      if(!live()||!document.getElementById(container)){stopStall();return}
      removeWidget();
      if(!live()){stopStall();return}
      widgetId=api.render(`#${container}`,{sitekey:siteKey,action,appearance:'interaction-only',
        callback:(token)=>{if(!live())return;stopStall();tokenSeenV286=true;stopSlowNoteV286();onToken(token);retryEl.hidden=true;setPassed(true)},
        /* v193: when Cloudflare escalates to a checkbox, the status used to sit on "Loading
           security check…" and the buttons it gates stayed disabled — so Sign in read "Checking…"
           and the passkey button looked broken while the app was simply waiting for a tick. */
        'before-interactive-callback':()=>{if(!live())return;stopStall();message(security('interactive'))},
        'after-interactive-callback':()=>{if(!live())return;armStall(mine);message(security('loading'))},
        'expired-callback':()=>{if(!live())return;stopStall();clear(security('expired'),true);retryEl.hidden=false},
        'timeout-callback':()=>{if(!live())return;stopStall();clear(security('timeout'),true);retryEl.hidden=false},
        'error-callback':(errorCode)=>{if(!live())return true;stopStall();logTurnstileError(errorCode);clear(security('connect'),true);retryEl.hidden=false;return true}});
    }catch{
      stopStall();
      /* The one guarantee this whole block exists to make: on ANY failure the user sees what
         happened and gets a Retry. Never a hidden button under a permanent "Loading…". */
      if(live()){clear(security('load'),true);retryEl.hidden=false}
    }
  };
  const retryRender=()=>{if(destroyed)return;clear(security('continue'));retryEl.hidden=true;render()};
  const reset=()=>{if(destroyed)return;clear(security('continue'));retryEl.hidden=true;if(api&&widgetId!==undefined)api.reset(widgetId);else render()};
  const destroy=()=>{
    if(destroyed)return;
    destroyed=true;generation+=1;stopStall();stopSlowNoteV286();
    retryEl.onclick=null;removeWidget();mountedTurnstileControls.delete(control);
  };
  const control={reset,destroy};
  mountedTurnstileControls.add(control);
  retryEl.onclick=retryRender;
  await render();
  return control;
}
/* Supabase Auth has CAPTCHA protection enabled (Cloudflare Turnstile), so every
   signUp / signInWithPassword / resetPasswordForEmail call must carry a captchaToken.
   The site key is public by design (the join/booking pages already expose the same
   widget's key); the secret lives only in Supabase Auth settings. */
const AUTH_TURNSTILE_SITE_KEY='0x4AAAAAAD4_7rnuzB3ug-NF';
/* The private database flags are the normal release authority. This build-time
   switch exists only for an emergency fail-closed build; it must never enable a
   server-disabled feature. */
const CUSTOMER_FEATURES_EMERGENCY_DISABLED=false;
function authChallengeHtml(locale='en'){
  return `<div class="challenge"><div id="authTurnstile"></div>
    <p class="challenge-status" id="authTurnstileStatus" role="status" aria-live="polite">${esc(authSecurityCopy(locale,'loading'))}</p>
    <button class="challenge-retry" id="authTurnstileRetry" type="button" hidden>${esc(authSecurityCopy(locale,'retry'))}</button></div>`;
}
let passwordRecoveryActive=false,passwordRecoveryError=false;

const MODULES={dashboard:['home','Dashboard'],till:['till','Record sale'],clients:['customers','Customers'],appointments:['appointments','Appointments'],
  sales:['sales','Sales & refunds'],services:['services','Services'],bookings:['bookings','Bookings'],waitlist:['waitlist','Waitlist'],
  inventory:['inventory','Products'],packages:['packages','Packages'],branches:['branch','Branches'],loyalty:['loyalty','Loyalty'],
  retention:['retention','Retention'],referrals:['referrals','Referrals'],memberships:['memberships','Memberships'],
  giftcards:['giftcard','Gift cards'],reports:['reports','Business Insights'],customerintel:['customers','Customer intelligence'],staffperf:['staff','Staff performance'],
  dailyreport:['daily','Daily report'],pnl:['pnl','P&L'],expenses:['expenses','Expenses'],
  staffmembers:['staff','Staff Members'],settings:['settings','Settings'],setup:['setup','Get started'],
  /* V275: two bar-only surfaces. 'bottles' is a real entitlement key (module_registry + the bar
     sector bundle); 'bottlesetup' is a surface key like 'branches' — owner-only configuration
     that lives in Operations setup, never an entitlement a staff member can be granted. */
  bottles:['bottle','Bottles'],bottlesetup:['bottle','Bottle keep']};
/* Canonical role set (v14 bug fix) — receptionist/stylist no longer exist as roles;
   frontdesk replaces receptionist. Used everywhere a role needs a human-readable label. */
const ROLE_LABELS={owner:'Owner',manager:'Manager',staff:'Staff',frontdesk:'Front desk',bookkeeper:'Bookkeeper'};
const ROLE_CAPABILITIES={
  owner:new Set(['create_sales','view_finance']),manager:new Set(['create_sales','view_finance']),staff:new Set(['create_sales']),
  frontdesk:new Set(['create_sales']),bookkeeper:new Set(['view_finance'])
};
/* V170 re-opened both surfaces the earlier packaging decision had hidden. Inventory is the only
   place a product can be created, so hiding it left owners unable to stock the checkout catalogue
   at all; Customer intelligence is the only screen carrying the ranked "do this first" advice, and
   a route-blocked recommendation surface is worse than no recommendation. The constant and both
   consult sites (the route guard and the nav filter) stay in place so a future packaging decision
   has one deny-list to fill instead of two hard-coded checks. */
const HIDDEN_BUSINESS_SURFACES=new Set([]);
const FINANCE_MODULES=new Set(['expenses','pnl','staffperf']);
const OWNER_ONLY_MODULES=new Set(['branches','staffmembers','settings','setup','bottlesetup']);
const BOTTLE_SURFACES_V275=new Set(['bottles','bottlesetup']);
const roleCanUseModule=(role,module)=>!FINANCE_MODULES.has(module)
  ||ROLE_CAPABILITIES[role]?.has('view_finance')===true;
const filterResolvedModulesForRole=(modules,role)=>[...(Array.isArray(modules)?modules:[])]
  .filter(module=>(role==='owner'||!OWNER_ONLY_MODULES.has(module))&&roleCanUseModule(role,module));

/* Global top-bar action state (no localStorage in this stack — plain in-session vars). A global
   search hands a name to Customers or a phone to Record sale via these, reusing each page's own
   existing lookup — no new query is introduced. settingsActiveTab keeps the Settings tab in place
   across the in-place re-renders that adding/retiring a customer field trigger. */
let pendingCustomerSearch='';
let pendingTillPhone='';
let pendingApptClientId=''; // Customer 360 → New appointment: prefills the existing #ac select, consumed once
/* V217. Owner: "new appointment here does not work (in the header - beside record sale)".
   It navigated to #/appointments and stopped there, with the booking form still collapsed
   behind its own button — so a control labelled "New appointment" produced a calendar and no
   form. This flag is consumed once by the appointments page, exactly like pendingApptClientId. */
let pendingOpenApptFormV217=false;
/* V229 (owner: "i need a clean overview before zooming in"). Which Programmes topic is drilled
   into, '' = the tile overview. In-session only, consumed by growPage. */
let growTopicV229='';
let settingsActiveTab='modules';
let profileOpen=false;
let routeDispose=()=>{};
let activeCustomerRedemptionCleanup=()=>{};
function disposeCurrentRoute(){
  const dispose=routeDispose;routeDispose=()=>{};
  dispose({restoreFocus:false});
  activeMerchantScannerCleanup();
  activeCustomerRedemptionCleanup({restoreFocus:false});
  activeCustomerJoinScannerCleanup({restoreFocus:false});
  document.querySelectorAll('.appointment-detail-modal').forEach(dialog=>dialog.remove());
}
let rtChannel=null;       // the single realtime channel for this session
let rtChannelBizId=null;  // which business it's currently subscribed to
let muteAlerts=false;     // in-session-only pop-up mute for non-owners (can't persist — the
                           // notify_new_bookings write is owner-gated by set_booking_settings)
/* Branch filter (dashboard/daily report/P&L/reports) — consolidated vs one branch. Plain
   JS variable only (no localStorage, per this stack's rule); shared across those pages so
   moving between them keeps the same scope selected; reset on sign-out below. */
let selectedBranchId=null; // null = consolidated
let dashboardRenderEpoch=0; // invalidates pending dashboard/filter work as soon as routing starts
let customerWalletRenderEpoch=0; // prevents an older customer-wallet RPC from repainting a new route
let routeRenderEpoch=0; // prevents an older async route from redirecting over newer navigation
let portalRenderEpoch=0; // prevents delayed persona/profile/session work repainting another portal/route
const beginRouteInvocation=()=>{
  const routeEpoch=++routeRenderEpoch;
  return ()=>routeRenderEpoch===routeEpoch;
};

let S={user:null,biz:null,charts:[],myModules:null,myModulePerms:null,myRole:null,isSA:false,saChecked:false,hasCustomerPersona:null,staffWorkspaces:[],customerProfile:null};
const PRODUCT_INTERACTION_EVENTS_V100=new Set([
  'merchant.workspace_viewed','merchant.grow_opened','merchant.grow_draft_started',
  'merchant.counter_action_opened','merchant.counter_action_started',
  'merchant.redemption_scan_started','customer.programme_viewed',
  /* v255: the taxonomy rows behind these names are already in the database. This allowlist is
     the second half of the same contract — a name absent here is never sent, and a name absent
     there is refused with 22023. */
  'merchant.surface_viewed','customer.session_started','customer.surface_viewed',
  'customer.promotion_viewed','customer.promotion_opened','customer.reward_viewed',
  'customer.notification_opened','customer.explore_searched',
  /* v265: a customer sharing a promotion. The taxonomy row is in the database (v265 migration);
     both halves must name it or the write is refused with 22023. */
  'customer.promotion_shared'
]);
/* Business discovery is genuinely tenant-free: the customer is looking for a business they have
   no relationship with, so attaching one would be a fiction. Every OTHER customer event stays
   business-scoped and is dropped without one. */
const PRODUCT_INTERACTION_UNSCOPED_EVENTS_V256=new Set(['customer.explore_searched']);
const PRODUCT_INTERACTION_CONTEXT_KEYS_V100=new Set([
  'action_key','entry_point','locale','device_class','install_mode','surface_version','outcome',
  'surface_key','promotion_id','query_shape'
]);
const PRODUCT_INTERACTION_SESSION_KEY_V100='nestly.productAdoption.session.v100';
let productInteractionSessionIdV100=null;
const PRODUCT_INTERACTION_BATCH_SIZE_V256=10;
const PRODUCT_INTERACTION_BATCH_MAX_V256=50;
const PRODUCT_INTERACTION_BATCH_IDLE_MS_V256=5000;
const PRODUCT_INTERACTION_QUEUE_CAP_V256=50;
const PRODUCT_INTERACTION_SESSION_START_KEY_V256='nestly.productAdoption.sessionStarted.v255';
let productInteractionQueueV256=[];
let productInteractionFlushTimerV256=0;
let productInteractionFlushInFlightV256=false;
let productInteractionAccessTokenV256='';
let productInteractionFlushBoundV256=false;
let productInteractionSessionStartedV256=false;
const isUuidV100=value=>/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value||''));
function productInteractionSessionV100(){
  if(isUuidV100(productInteractionSessionIdV100))return productInteractionSessionIdV100;
  try{
    const stored=sessionStorage.getItem(PRODUCT_INTERACTION_SESSION_KEY_V100);
    if(isUuidV100(stored))return productInteractionSessionIdV100=stored;
  }catch{}
  productInteractionSessionIdV100=crypto.randomUUID();
  try{sessionStorage.setItem(PRODUCT_INTERACTION_SESSION_KEY_V100,productInteractionSessionIdV100)}catch{}
  return productInteractionSessionIdV100;
}
function resetProductInteractionSessionV100(){
  productInteractionSessionIdV100=null;
  /* Anything still queued belongs to the session that just ended. The server attributes on
     auth.uid(), so flushing it after a different sign-in would hand one person's taps to
     another. Dropping is the only safe option, and telemetry is allowed to be lossy. */
  productInteractionQueueV256=[];
  productInteractionSessionStartedV256=false;
  try{sessionStorage.removeItem(PRODUCT_INTERACTION_SESSION_KEY_V100)}catch{}
  try{sessionStorage.removeItem(PRODUCT_INTERACTION_SESSION_START_KEY_V256)}catch{}
}
function privacySafeProductContextV100(context={}){
  const safe={};
  for(const [key,value] of Object.entries(context||{})){
    if(!PRODUCT_INTERACTION_CONTEXT_KEYS_V100.has(key)
       ||!['string','number','boolean'].includes(typeof value))continue;
    safe[key]=typeof value==='string'?value.slice(0,80):value;
  }
  return safe;
}
/* v255 batching. Instrumenting route views, promotion views and search shapes turns one request
   per tap into ten, which on a phone on 4G is a tax the customer pays for our analytics. Events
   now accumulate and leave in one call: at 10 queued, after 5s of quiet, and on the page going
   away. The queue is capped and drops the OLDEST on overflow, because unbounded telemetry in a
   long-lived tab is a memory leak.

   No sendBeacon: it cannot carry the Authorization header this RPC needs. On pagehide we do a
   best-effort keepalive fetch and accept the loss when it does not land. */
function productInteractionKeepaliveV256(events){
  if(!productInteractionAccessTokenV256)return false;
  try{
    fetch(`${SB_URL}/rest/v1/rpc/record_product_interactions_batch_v255`,{
      method:'POST',keepalive:true,
      headers:{'content-type':'application/json','apikey':SB_KEY,
        'authorization':`Bearer ${productInteractionAccessTokenV256}`},
      body:JSON.stringify({p_events:events})
    }).catch(()=>{});
    return true;
  }catch{return false}
}
function flushProductInteractionsV256(keepalive){
  if(productInteractionFlushTimerV256){
    clearTimeout(productInteractionFlushTimerV256);productInteractionFlushTimerV256=0;
  }
  if(!productInteractionQueueV256.length)return;
  if(productInteractionFlushInFlightV256&&!keepalive)return;
  const events=productInteractionQueueV256.splice(0,PRODUCT_INTERACTION_BATCH_MAX_V256);
  try{
    if(keepalive&&productInteractionKeepaliveV256(events))return;
    productInteractionFlushInFlightV256=true;
    const settleV256=()=>{
      productInteractionFlushInFlightV256=false;
      if(productInteractionQueueV256.length)flushProductInteractionsV256(false);
    };
    Promise.resolve(sb.rpc('record_product_interactions_batch_v255',{p_events:events}))
      .then(settleV256,settleV256);
  }catch{productInteractionFlushInFlightV256=false}
}
function bindProductInteractionFlushV256(){
  if(productInteractionFlushBoundV256)return;
  productInteractionFlushBoundV256=true;
  try{
    document.addEventListener('visibilitychange',()=>{
      if(document.visibilityState==='hidden')flushProductInteractionsV256(true);
    });
    window.addEventListener('pagehide',()=>flushProductInteractionsV256(true));
    /* The keepalive path needs a bearer token synchronously, and getSession() is async — on
       pagehide there is no time to await it. Bound lazily so a page that never records anything
       never subscribes. */
    sb.auth.onAuthStateChange((_event,session)=>{
      productInteractionAccessTokenV256=session?.access_token||'';
    });
    Promise.resolve(sb.auth.getSession()).then(result=>{
      productInteractionAccessTokenV256=result?.data?.session?.access_token||'';
    },()=>{});
  }catch{}
}
/* Records the SHAPE of a search, never the words. Token count, a coarse length bucket and
   whether anything matched are enough to say "customers keep asking for something nobody
   sells"; the typed text, joined to auth.uid(), would be re-identifying and PDPA-sensitive. */
function exploreQueryShapeV256(query,matched){
  const text=String(query||'').trim();
  const tokens=text?text.split(/\s+/).filter(Boolean).length:0;
  const length=text.length===0?'empty':text.length<=12?'short':text.length<=30?'medium':'long';
  return `t${Math.min(tokens,6)}:${length}:${matched?'matched':'unmatched'}`;
}
/* Interaction telemetry is deliberately fail-open. It records only that an allowed surface
   was opened or started; completed and economic outcomes remain database-authored. A missing
   migration, denied scope, or network failure must never delay or alter the user's action. */
/* V261: analytics is best-effort by contract — "a failed analytics request must NEVER break the
   user's actual Peekaa action". Every emit site is written as an inline
   `typeof recordProductInteractionV100==='function'&&…` guard: `typeof` is legal on an
   UNDECLARED identifier, so the guard survives a surface being evaluated without the core chunk.
   The v104 evidence fixture proved this is not hypothetical — an unguarded call threw a
   ReferenceError that stopped a customer opening a promotion. */
function recordProductInteractionV100(eventName,businessId,{branchId=null,context={}}={}){
  if(!S.user?.id||!PRODUCT_INTERACTION_EVENTS_V100.has(eventName))return;
  const scopedV256=isUuidV100(businessId);
  if(!scopedV256&&!PRODUCT_INTERACTION_UNSCOPED_EVENTS_V256.has(eventName))return;
  let eventV256;
  try{
    eventV256={
      event_name:eventName,
      business_id:scopedV256?businessId:null,
      branch_id:isUuidV100(branchId)?branchId:null,
      session_id:productInteractionSessionV100(),
      idempotency_key:`v100:${crypto.randomUUID()}`,
      occurred_at:new Date().toISOString(),
      context:privacySafeProductContextV100(context)
    };
  }catch{return}
  try{
    bindProductInteractionFlushV256();
    productInteractionQueueV256.push(eventV256);
    if(productInteractionQueueV256.length>PRODUCT_INTERACTION_QUEUE_CAP_V256){
      productInteractionQueueV256.splice(
        0,productInteractionQueueV256.length-PRODUCT_INTERACTION_QUEUE_CAP_V256
      );
    }
    if(productInteractionQueueV256.length>=PRODUCT_INTERACTION_BATCH_SIZE_V256){
      flushProductInteractionsV256(false);return;
    }
    if(productInteractionFlushTimerV256)clearTimeout(productInteractionFlushTimerV256);
    productInteractionFlushTimerV256=setTimeout(
      ()=>flushProductInteractionsV256(false),PRODUCT_INTERACTION_BATCH_IDLE_MS_V256
    );
  }catch{}
}
let customerFeatureCapabilities=null;
let customerPhoneOtpCapabilities=null;
let customerRelationshipSyncState={userId:null,attempted:false,result:null};
let pendingCustomerInvitationToken='';
let pendingCustomerBusinessSlug='';
const CUSTOMER_DESTINATION_SESSION_KEY='peekaa.customer.pendingDestination.v1';
let pendingCustomerDestination='';
const CUSTOMER_JOIN_SESSION_KEY='nestly.customer.pendingJoinToken';
const CUSTOMER_RECOVERY_SESSION_KEY='nestly.customer.passwordRecoveryVerified';
let pendingCustomerJoinToken=(()=>{try{
  const token=sessionStorage.getItem(CUSTOMER_JOIN_SESSION_KEY)||'';
  return /^[A-Za-z0-9_-]{20,512}$/.test(token)?token:'';
}catch{return ''}})();
function rememberPendingCustomerJoinToken(token){
  pendingCustomerJoinToken=/^[A-Za-z0-9_-]{20,512}$/.test(String(token||''))?String(token):'';
  try{
    if(pendingCustomerJoinToken)sessionStorage.setItem(CUSTOMER_JOIN_SESSION_KEY,pendingCustomerJoinToken);
    else sessionStorage.removeItem(CUSTOMER_JOIN_SESSION_KEY);
  }catch{}
}
function customerRecoveryVerified(){
  try{return sessionStorage.getItem(CUSTOMER_RECOVERY_SESSION_KEY)||''}catch{return ''}
}
function rememberCustomerRecoveryVerified(userId){
  try{
    if(userId)sessionStorage.setItem(CUSTOMER_RECOVERY_SESSION_KEY,String(userId));
    else sessionStorage.removeItem(CUSTOMER_RECOVERY_SESSION_KEY);
  }catch{}
}
function customerRecoveryDisposition(recoveryUserId,sessionUserId){
  if(!recoveryUserId)return 'none';
  return recoveryUserId===sessionUserId?'require_password':'clear';
}
function normalizeCustomerBusinessIntent(value,currentUrl=location.href){
  const raw=String(value??'').trim();
  if(!raw)return '';
  let candidate='';
  const isLink=/^(?:https?:\/\/|\/|\.{1,2}\/|#\/)/i.test(raw);
  if(!isLink){
    candidate=raw;
  }else{
    try{
      const url=new URL(raw,currentUrl);
      const hash=url.hash||'';
      const hashRoute=hash.split('?')[0];
      const hashParams=new URLSearchParams(hash.split('?')[1]||'');
      if(hashRoute.startsWith('#/b/'))candidate=hashRoute.slice(4);
      else if(hashRoute.startsWith('#/wallet/'))candidate=hashRoute.slice(9);
      else if(hashRoute==='#/customer'||hashRoute==='#/claim')candidate=hashParams.get('business')||'';
      else if(/\/join(?:\.html)?$/i.test(url.pathname))candidate=url.searchParams.get('s')||'';
      else {
        const pathMatch=url.pathname.match(/\/(?:b|wallet)\/([^/?#]+)\/?$/i);
        candidate=pathMatch?.[1]||'';
      }
    }catch{return ''}
  }
  try{candidate=decodeURIComponent(candidate)}catch{return ''}
  const normalized=String(candidate).trim().toLowerCase();
  return /^[a-z0-9][a-z0-9-]{1,62}$/.test(normalized)?normalized:'';
}
const CUSTOMER_DIRECT_DESTINATIONS=new Set([
  '#/wallet',
  '#/customer/programmes',
  '#/customer/bookings',
  '#/customer/messages',
  '#/customer/profile',
  /* V286: the marketing opt-out route the signup copy itself promises ("turn this off any time
     in Profile → Communications"). Without it a signed-out deep link fell through to
     renderAuth — the MERCHANT sign-in card — and nothing remembered where the visitor was
     going, so even a correct customer sign-in landed on the wallet instead. */
  '#/customer/communications'
]);
function normalizeCustomerDestination(value){
  const route=String(value??'').trim();
  if(CUSTOMER_DIRECT_DESTINATIONS.has(route))return route;
  if(!route.startsWith('#/wallet/'))return '';
  const slug=normalizeCustomerBusinessIntent(route.slice(9));
  return slug?`#/wallet/${encodeURIComponent(slug)}`:'';
}
try{pendingCustomerDestination=normalizeCustomerDestination(sessionStorage.getItem(CUSTOMER_DESTINATION_SESSION_KEY)||'')}catch{}
function rememberPendingCustomerDestination(value){
  pendingCustomerDestination=normalizeCustomerDestination(value);
  try{
    if(pendingCustomerDestination)sessionStorage.setItem(CUSTOMER_DESTINATION_SESSION_KEY,pendingCustomerDestination);
    else sessionStorage.removeItem(CUSTOMER_DESTINATION_SESSION_KEY);
  }catch{}
  return pendingCustomerDestination;
}
function completePendingCustomerDestination(route){
  const destination=normalizeCustomerDestination(pendingCustomerDestination);
  if(destination&&normalizeCustomerDestination(route)===destination)rememberPendingCustomerDestination('');
}
function resetClientSessionState({preserveInvitation=false}={}){
  globalThis.NestlyCustomerPush?.clearSession?.();
  invalidateBranchModuleProjectionCache();
  const invitation=preserveInvitation?pendingCustomerInvitationToken:'';
  const joinToken=preserveInvitation?pendingCustomerJoinToken:'';
  const destination=preserveInvitation?pendingCustomerDestination:'';
  if(!preserveInvitation)rememberPendingCustomerJoinToken('');
  rememberCustomerRecoveryVerified(false);
  S={user:null,biz:null,charts:[],myModules:null,myModulePerms:null,myRole:null,isSA:false,saChecked:false,hasCustomerPersona:null,staffWorkspaces:[],customerProfile:null};
  /* V286: the nav badge cache is per-person. Left standing, customer B's Rewards/Bookings tabs
     first-painted with customer A's counts on a shared phone until the wallet data landed. */
  customerNavCountsV194={programmes:0,bookings:0};
  customerFeatureCapabilities=null;customerPhoneOtpCapabilities=null;customerRelationshipSyncState={userId:null,attempted:false,result:null};pendingCustomerInvitationToken=invitation;rememberPendingCustomerJoinToken(joinToken);pendingCustomerBusinessSlug='';rememberPendingCustomerDestination(destination);selectedBranchId=null;profileOpen=false;
  pendingCustomerSearch='';pendingTillPhone='';pendingApptClientId='';pendingOpenApptFormV217=false;settingsActiveTab='modules';growTopicV229='';
  resetProductInteractionSessionV100();
  customerLocale='en';
  workspaceLocaleLoadedFor='';workspaceLocaleVersion=0;workspaceLocale='en';
  globalThis.document?.documentElement?.setAttribute('lang','en');
}
const $=(id)=>document.getElementById(id);
const root=$('root');
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const brandWordmark=()=>{
  const productName=String(BRAND?.productName||'Peekaa');
  const logoPath=String(BRAND?.logoPath||'/brand/peekaa-logo.png');
  return `<img class="brand-logo" src="${esc(logoPath)}" alt="${esc(productName)}">`;
};
const money=c=>(S.biz?.currency||'SGD')+' '+((c||0)/100).toFixed(2);
const canReadModule=module=>S.myModules?.includes(module)===true&&roleCanUseModule(S.myRole,module);
function invalidateBranchModuleProjectionCache({businessId='',branchId='',userId=''}={}){
  // Projections are deliberately fetched fresh on every route/branch load.
  // Keep this hook for mutation call sites and older callers, but do not store
  // identity or permission state that another session cannot invalidate.
  void businessId;void branchId;void userId;
}
let toastGeneration=0,toastTimer=null;
const showToast=message=>{
  const t=$('toast'),generation=++toastGeneration;
  if(toastTimer)clearTimeout(toastTimer);
  t.textContent=message;t.classList.add('show');
  toastTimer=setTimeout(()=>{
    if(generation!==toastGeneration)return;
    t.classList.remove('show');t.textContent='';toastTimer=null;
  },2600);
};
const toast=m=>{
  const source=String(m??''),message=root.querySelector('.shell')?workspaceTranslationV97(source):source;
  showToast(message);CUI.announce(message);
};
async function copyTextToClipboard(value,{button=null,success='Copied',failure='Copy was blocked. Select the text and copy it manually.'}={}){
  if(button)button.disabled=true;
  try{
    if(!navigator.clipboard?.writeText)throw new Error('Clipboard unavailable');
    await navigator.clipboard.writeText(String(value??''));
    if(success)toast(success);
    return true;
  }catch(error){
    console.warn('Clipboard copy failed',error);
    if(failure){showToast(failure);CUI.announce(failure,{assertive:true})}
    return false;
  }finally{
    if(button?.isConnected)button.disabled=false;
  }
}
/* V170 (reworked after adversarial verification): this codebase's own RPCs raise owner-facing
   prose that is almost always lowercase-first ("choose Cash, Card, PayNow or Other",
   "no sessions remaining" — ~96% of the 2k+ raise-exception strings in db/migrations). A
   "looks like a sentence" heuristic therefore CANNOT identify owner-authored text, and keyword
   rules ("session", "unique") actively mislabel it. So the mapping is inverted: pass every
   message through by default, and rewrite ONLY messages that match known machine-noise
   signatures no RPC author ever writes on purpose. */
const OWNER_ERROR_NOISE_RULES_V170=[
  [/duplicate key value violates|violates unique constraint/i,'This already exists — no duplicate was created.'],
  [/violates (foreign key|not-null|check) constraint|null value in column/i,"That change couldn't be saved. Check the details and try again."],
  [/permission denied for (table|function|schema|relation)|row-level security/i,"You don't have access to do that. Ask an owner to check your permissions."],
  [/jwt expired|invalid jwt|jwserror|auth session missing|refresh token/i,'Your session expired. Sign in again.'],
  [/failed to fetch|networkerror|load failed|fetch failed|timed? ?out/i,'Connection problem. Check your internet and try again.'],
  [/schema cache|pgrst\d+|syntax error at or near/i,'Something went wrong on our side. Try again, or contact Peekaa if it continues.'],
  /* Browser-runtime TypeErrors (WebKit: "undefined is not an object (evaluating ...)",
     Chromium: "Cannot read properties of undefined") are app bugs, never owner input errors. */
  [/undefined is not an object|null is not an object|cannot read propert|is not a function|is not defined/i,'Something went wrong on our side. Try again, or contact Peekaa if it continues.'],
  /* V217. The owner was shown the bare string `foreign_or_inactive_branch_scope` where the
     customer list should have been. These are precise server codes and correct ones, but they
     are not sentences. They are translated here rather than at each call site so every surface
     that surfaces a server error gets the plain-English version. */
  [/foreign_or_inactive_branch_scope/i,'The branch being viewed is switched off or waiting for payment. Choose another branch at the top.'],
  [/unauthorised_branch_scope|branch_visibility/i,'You do not have access to the branch being viewed. Choose another branch at the top.'],
  [/operational_branch_required_for_current_scope/i,'No branch is selected. Choose one at the top.'],
  [/empty_selected_branch_scope/i,'Choose at least one branch to report on.'],
  [/unsupported_reporting_branch_scope/i,'That reporting scope is not supported. Choose a branch at the top.'],
];
const ownerErrorText=error=>{
  const raw=String(error?.message||(typeof error==='string'?error:'')||'').trim();
  if(!raw)return 'Something went wrong. Nothing was changed.';
  const probe=[raw,error?.code,error?.details].filter(Boolean).join(' ');
  for(const rule of OWNER_ERROR_NOISE_RULES_V170)if(rule[0].test(probe))return rule[1];
  return raw;
};
const fail=e=>{
  console.error(e);
  const source=ownerErrorText(e);
  const translated=root.querySelector('.shell')?workspaceTranslationV97(source):source;
  const message=root.querySelector('.shell')&&workspaceLocale!=='en'&&translated===source
    ?workspaceTranslationV97('Something went wrong. Please try again.')
    :translated;
  showToast(message);CUI.announce(message,{assertive:true});
};
let activeMerchantScannerCleanup=()=>{};
function campaignEntitlementDisplayV99(item){
  const campaign=!!(item?.is_campaign_entitlement===true||item?.campaign_id);
  const pending=campaign
    &&item?.economic_value_posted!==true
    &&(item?.reward_value_hidden===true
      ||!item?.redemption_mode||item.redemption_mode==='merchant_fulfilment_pending');
  return pending?{
    pending:true,
    title:String(item?.display_label||'Offer awaiting merchant fulfilment'),
    status:'Merchant fulfilment pending',
    detail:'No wallet value was posted. The business must fulfil this reward before it can be used.',
    showValue:false
  }:{
    pending:false,
    title:String(item?.reward_label||item?.title||'Retention reward'),
    status:String(item?.status||''),
    detail:String(item?.detail||''),
    showValue:true
  };
}
/* --- Idempotent write-attempt key (survives a full page re-render) -------------------------
   Safety-remediation house pattern — the same discipline as the Quick-earn cart's `saleIdem`
   / per-line uuid keys and retentionPage's sessionStorage retry key. One stable uuid per
   LOGICAL write attempt: minted when an attempt's fingerprint first appears, then reused
   VERBATIM on every retry (double-tap, timeout, lost response, route re-render, reconnect),
   and regenerated ONLY when the user deliberately changes the inputs (the fingerprint changes)
   or after the attempt settles — clearWriteAttempt() on success or on a same-key/different-
   payload conflict, so the next deliberate attempt is fresh. It rides in sessionStorage — the
   one storage primitive this stack allows (localStorage is prohibited) — so the key outlives
   both the click closure AND a full page-function re-invocation, unlike a page-scoped `let`.
   Button-disabling is UI polish, NOT the idempotency story; the server dedupes on this key. */
const writeAttemptKey=(slot,fingerprint)=>{
  let a=null;try{a=JSON.parse(sessionStorage.getItem(slot)||'null')}catch{}
  if(!a||a.fingerprint!==fingerprint){
    a={fingerprint,key:crypto.randomUUID()};
    try{sessionStorage.setItem(slot,JSON.stringify(a))}catch{}
  }
  return a.key;
};
const clearWriteAttempt=slot=>{try{sessionStorage.removeItem(slot)}catch{}};
/* Singapore-fixed-offset (UTC+8) display helper: shows a stored UTC instant as SGT wall-clock
   text, regardless of the viewer's own browser/system timezone. Frenly is SG-first — bookings
   are always shown in SGT so "what the customer picked is what staff see". */
const sgt=iso=>{if(!iso) return null;const d=new Date(new Date(iso).getTime()+8*3600000);return d.toISOString().slice(0,16).replace('T',' ')};
/* Turn a <input type=datetime-local> value (always "YYYY-MM-DDTHH:mm", locale-free) into a
   UTC ISO string by anchoring it explicitly to Singapore time (+08:00) instead of relying on
   the browser's ambient system timezone — avoids the local-vs-UTC mismatch bug. */
const sgIso=v=>v?new Date(v+':00+08:00').toISOString():null;
const sgDateInputValue=(date=new Date())=>{
  const values={};
  new Intl.DateTimeFormat('en-CA',{
    timeZone:'Asia/Singapore',year:'numeric',month:'2-digit',day:'2-digit'
  }).formatToParts(date).forEach(part=>{if(part.type!=='literal')values[part.type]=part.value});
  return `${values.year}-${values.month}-${values.day}`;
};
/* reporting-scale:end */
function killCharts(){S.charts.forEach(c=>c.destroy());S.charts=[]}
/* V289 (audit A3, G1 — "registration completes then freezes"). Routing is driven ONLY by
   hashchange, and assigning location.hash a value it already holds fires no hashchange. Every
   nav() to the route already on screen was therefore a silent no-op: after
   customer_register_verified_phone succeeded, resolveCustomerRegistrationDestination called
   nav('#/join') from '#/join' (or nav(destination) from that destination) and nothing happened —
   the account existed, the button stayed on "Creating your account…" forever, and the only way
   out was a manual reload. Two call sites already worked around this locally (the app-bar search
   handler's goTo, and the New appointment button); the workaround belongs in the primitive, so
   no future caller has to remember it. route() is safe to re-enter: it takes a fresh
   beginRouteInvocation() epoch on entry, which invalidates every in-flight older render. */
function nav(h){if(location.hash===h)route();else location.hash=h}
window.addEventListener('hashchange',route);
/* "/" or ⌘K / Ctrl+K focuses the global customer search from anywhere in the workspace. "/"
   is ignored while the user is typing in a field so it can't hijack normal input. The listener
   is attached once and resolves #globalSearch at event time, so it survives every shell re-render
   and no-ops on routes (auth, portal, wallet) where the app bar isn't present. */
function handleGlobalSearchHotkey(e){
  const input=document.getElementById('globalSearch');
  if(!input)return;
  const cmdK=(e.key==='k'||e.key==='K')&&(e.metaKey||e.ctrlKey);
  const slash=e.key==='/'&&!e.metaKey&&!e.ctrlKey&&!e.altKey;
  if(!cmdK&&!slash)return;
  const t=e.target;
  const typing=t&&(t.tagName==='INPUT'||t.tagName==='TEXTAREA'||t.tagName==='SELECT'||t.isContentEditable);
  if(slash&&typing)return;
  e.preventDefault();input.focus();if(input.select)input.select();
}
document.addEventListener('keydown',handleGlobalSearchHotkey);

const unavailableCustomerCapabilities=(loadError=false)=>({customer_identity:false,customer_claims:false,
  customer_wallet:false,customer_actions:false,customer_notifications:false,customer_email_otp:false,
  customer_phone_otp:false,customer_whatsapp_otp:false,customer_phone_registration:false,customer_phone_claims:false,
  customer_actionable_wallet:false,customer_birthday_benefits:false,customer_in_app_inbox:false,_load_error:loadError});
async function loadCustomerFeatureCapabilities({refresh=false}={}){
  if(CUSTOMER_FEATURES_EMERGENCY_DISABLED) return unavailableCustomerCapabilities();
  if(customerFeatureCapabilities&&!refresh) return customerFeatureCapabilities;
  const {data,error}=await sb.rpc('get_customer_feature_capabilities');
  if(error)return unavailableCustomerCapabilities(true);
  customerFeatureCapabilities={...unavailableCustomerCapabilities(),...(data||{})};
  return customerFeatureCapabilities;
}

/* v185 surface chunks. app/app.js is still the one file anybody edits; the build partitions it by
   surface (scripts/quality/split-app-bundle.mjs) and index.html loads only the shared core. The
   customer chunk and the workspace chunk arrive on demand, so someone opening a booking link no
   longer downloads the till, reports, inventory and settings code. Urls come from the
   #appSurfaceChunks manifest, which the build stamps with each chunk's own byte fingerprint. */
const APP_SURFACE_CHUNKS_V185=(()=>{
  try{return JSON.parse(document.getElementById('appSurfaceChunks')?.textContent||'{}')}catch{return {}}
})();
/* V200 surface assets. grow-recommender.js, v95-media-sync.js, revenue-truth.js, growth-offers.js
   and sector-economics.js (plus their stylesheets) were plain <script defer>/<link> tags in
   index.html, so every visitor — including a customer opening a booking link — downloaded, parsed
   and ran all of them before first paint, for globals only a workspace page or the customer offer
   strip ever touches. Every consumption site sits inside a function, so they can arrive with the
   surface that needs them. They are injected BEFORE the surface chunk and with async=false, which
   means that even if a future edit does read one of these globals at chunk load time, the global is
   already there. A failure resolves rather than rejects: a missing enhancement must not stop the
   surface from rendering, exactly as a failed <script defer> did not stop boot. */
const APP_SURFACE_ASSETS_V200=(()=>{
  try{return JSON.parse(document.getElementById('appSurfaceAssets')?.textContent||'{}')}catch{return {}}
})();
const surfaceAssetPromisesV200=new Map();
/* Same-origin absolute paths only, and each url is fetched once however many surfaces list it —
   growth-offers is shared by the customer and the workspace surfaces. */
function loadSurfaceAssetV200(url,kind){
  const src=String(url||'');
  if(!/^\/[\w./?=-]*$/.test(src))return Promise.resolve('');
  if(surfaceAssetPromisesV200.has(src))return surfaceAssetPromisesV200.get(src);
  const promise=new Promise(resolve=>{
    const node=document.createElement(kind==='css'?'link':'script');
    if(kind==='css'){node.rel='stylesheet';node.href=src}
    else {node.src=src;node.async=false}
    node.onload=()=>resolve(src);
    node.onerror=()=>{console.error(`Surface asset failed to load: ${src}`);resolve('')};
    document.head.appendChild(node);
  });
  surfaceAssetPromisesV200.set(src,promise);
  return promise;
}
function loadSurfaceAssetsV200(name){
  const entry=APP_SURFACE_ASSETS_V200[name]||{};
  const css=Array.isArray(entry.css)?entry.css:[];
  const js=Array.isArray(entry.js)?entry.js:[];
  return Promise.all([...css.map(url=>loadSurfaceAssetV200(url,'css')),...js.map(url=>loadSurfaceAssetV200(url,'js'))]);
}
const appChunkPromisesV185=new Map();
let appSurfaceRetriedV185=false;
/* v200: surfaces that cannot stand alone. The workspace chunk is built on the assumption that the
   auth chunk is already there — a persona chooser, a suspended-workspace card and the invite
   acceptance screen are reached both signed out AND from inside the workspace, so they live in the
   small chunk and the big one declares the dependency instead of duplicating them or pushing them
   back into the always-loaded core. Mirrors SURFACE_PREREQUISITES in
   scripts/quality/split-app-bundle.mjs, which refuses to build a chunk that breaks the rule. */
const APP_SURFACE_PREREQUISITES_V185={business:['auth']};
function loadAppChunkV185(name){
  if(appChunkPromisesV185.has(name))return appChunkPromisesV185.get(name);
  const src=String(APP_SURFACE_CHUNKS_V185[name]||'');
  /* Same-origin absolute paths only — a missing or tampered manifest must never become a script
     injection point. */
  if(!/^\/[\w./?=-]*$/.test(src)){
    const missing=Promise.reject(new Error(`Application chunk "${name}" is not available.`));
    missing.catch(()=>{});appChunkPromisesV185.set(name,missing);return missing;
  }
  /* The prerequisite chunk and this surface's assets are injected FIRST. Every tag carries
     async=false, so the browser downloads them in parallel but executes them in insertion order —
     whatever the chunk depends on is defined before its first line runs, without serialising the
     round trips. */
  const prerequisites=(APP_SURFACE_PREREQUISITES_V185[name]||[]).map(dependency=>loadAppChunkV185(dependency));
  prerequisites.push(loadSurfaceAssetsV200(name));
  const promise=new Promise((resolve,reject)=>{
    const script=document.createElement('script');
    script.src=src;script.async=false;
    script.onload=()=>resolve(name);
    script.onerror=()=>{appChunkPromisesV185.delete(name);reject(new Error('Part of the app could not be loaded. Check your connection and reload.'))};
    document.head.appendChild(script);
  });
  /* A rejection drops the cache entry too, so a retry genuinely re-requests instead of re-awaiting
     the failure. */
  const ready=Promise.all([...prerequisites,promise])
    .then(()=>name,error=>{appChunkPromisesV185.delete(name);throw error});
  appChunkPromisesV185.set(name,ready);
  return ready;
}
/* Which chunk a route needs. The hash alone is not enough — "#/" is the customer entry for a
   signed-out visitor and the workspace for signed-in staff — so the caller passes the session it
   already resolved. Anything unrecognised loads the workspace, which is the historical default,
   and a wrong guess is self-healing (see the ReferenceError branch in route). */
/* V243: '#/customer' was a bare prefix, so ANY future workspace route beginning with those
   nine characters — the new '#/customer-interface' is the first — was classified as a customer
   route and downloaded the customer chunk instead of the workspace one. '#/customer/' plus the
   matcher's own exact-equality branch covers '#/customer', '#/customer?…' and '#/customer/…'
   exactly as before, and nothing else. The inline preloader in index.html mirrors this list. */
const CUSTOMER_ROUTE_PREFIXES_V185=['#/b/','#/customer/','#/wallet','#/claim','#/join','#/offer/'];
function appSurfaceForRouteV185(hash,{signedIn=false}={}){
  const route=String(hash||'').split('?')[0];
  if(route.startsWith('#/platform'))return null;
  if(CUSTOMER_ROUTE_PREFIXES_V185.some(prefix=>route===prefix.replace(/\/$/,'')||route.startsWith(prefix)))return 'customer';
  /* V199: "#/" is a CUSTOMER entry point in every case, signed in or not — route() sends it to
     renderCustomerRegistration unconditionally, which then forwards a customer with a profile on
     to #/wallet. Staff reach the workspace through #/business. The old signedIn?'business' branch
     described a route that never existed, so every signed-in visitor to the bare root loaded the
     workspace chunk, threw ReferenceError: renderCustomerRegistration, and fell back to
     downloading EVERY surface — the self-heal worked, so it only ever showed up as wasted
     bandwidth on the most-hit route. */
  if(route==='#/'||route==='')return 'customer';
  /* V200: a signed-out merchant on /business is shown one card — sign in, sign up, accept an
     invite, or activate an approved business. That used to cost the entire 1.2MB workspace chunk
     before the form could be typed into. Those screens are their own ~17KB chunk now; the
     workspace only downloads once there IS a session to open it with (and it pulls the auth chunk
     along with it, so the signed-in persona/suspension screens are still present). */
  return signedIn?'business':'auth';
}
/* v184: the Peekaa admin console is ~210KB of JS + CSS that only a platform admin can use. It
   used to be a plain <script defer> in index.html, so every customer opening a booking page paid
   for it. Its urls live in the #platformConsoleAssets manifest (one place to bump the version);
   this fetches them the first time a #/platform route is requested and caches the promise, so a
   second admin navigation costs nothing. Resolves to the console module, or null when it cannot
   be loaded — the caller already renders a recoverable error for that. */
let platformConsoleAssetsPromiseV184=null;
function loadPlatformConsoleAssetsV184(){
  if(globalThis.NestlyPlatformConsole)return Promise.resolve(globalThis.NestlyPlatformConsole);
  if(platformConsoleAssetsPromiseV184)return platformConsoleAssetsPromiseV184;
  let assets={};
  try{assets=JSON.parse(document.getElementById('platformConsoleAssets')?.textContent||'{}')}catch{assets={}}
  const scriptUrl=String(assets.js||''),styleUrl=String(assets.css||''),crmUrl=String(assets.crm||'');
  if(!scriptUrl.startsWith('/')){
    /* A missing or tampered manifest must not become a script injection. */
    return Promise.resolve(null);
  }
  platformConsoleAssetsPromiseV184=new Promise(resolve=>{
    if(styleUrl.startsWith('/')&&!document.querySelector(`link[href="${CSS.escape(styleUrl)}"]`)){
      const style=document.createElement('link');
      style.rel='stylesheet';style.href=styleUrl;document.head.appendChild(style);
    }
    /* V200: NestlyPlatformCRMUtils has exactly one consumer — platform-console.js — so it moved off
       the initial page load and onto this path. Injected before the console and with async=false,
       so it is defined by the time the console's first line runs. */
    if(crmUrl.startsWith('/')){
      const crm=document.createElement('script');
      crm.src=crmUrl;crm.async=false;document.head.appendChild(crm);
    }
    const script=document.createElement('script');
    /* async=false, not defer: `defer` is ignored on a dynamically created script, which would leave
       this racing the CRM helper above — and platform-console.js reads NestlyPlatformCRMUtils at
       ITS load time (`const CRM=globalObject.NestlyPlatformCRMUtils||null`). async=false is the
       only flag that guarantees the two execute in insertion order. */
    script.src=scriptUrl;script.async=false;
    script.onload=()=>resolve(globalThis.NestlyPlatformConsole||null);
    script.onerror=()=>{platformConsoleAssetsPromiseV184=null;resolve(null)};
    document.head.appendChild(script);
  });
  return platformConsoleAssetsPromiseV184;
}
/* ---------- routing ---------- */
/* V288: the parameters of the route currently being rendered. route() fills this in as it
   strips the query string off the hash, so a page can read `?view=list&preset=today` without
   re-parsing location.hash (which may already have moved on). */
let routeQueryParamsV288=new URLSearchParams('');
function entryRouteForLocation(pathname=location.pathname,hash=location.hash){
  const requested=String(hash||'').trim();
  if(requested&&requested!=='#'&&requested!=='#/')return requested;
  const cleanPath=(String(pathname||'/').replace(/\/+$/,'')||'/').toLowerCase();
  if(cleanPath==='/business')return '#/business';
  if(cleanPath==='/admin')return '#/platform';
  return '#/';
}
async function route(){
  const isRouteCurrent=beginRouteInvocation();
  dashboardRenderEpoch+=1;
  customerWalletRenderEpoch+=1;
  portalRenderEpoch+=1;
  destroyMountedTurnstiles();
  globalThis.document?.documentElement?.setAttribute('lang','en');
  globalThis.document?.documentElement?.removeAttribute('data-customer-surface');
  disposeCurrentRoute();
  if(typeof customerAccountMenuCleanup==='function')customerAccountMenuCleanup();
  /* Boot/nav must never leave a blank page behind — a transient network blip or a Supabase
     hiccup used to throw straight out of this async function with nothing rendered, which
     read to the owner as "pressing refresh does nothing." Now it's recoverable in-place. */
  try{
    killCharts();
    if(passwordRecoveryError) return renderRecoveryInvalid();
    if(passwordRecoveryActive) return renderPasswordUpdate();
    let h=entryRouteForLocation();
    if(h==='#/login')h='#/business';
    if(h.startsWith('#/business?'))h='#/business';
    if(h==='#/programmes'||h.startsWith('#/programmes/'))h=h.replace('#/programmes','#/grow');
    const staffInviteCodeV151=businessStaffInviteCodeV151();
    const platformRoutePath=String(h).split('?')[0].replace(/\/+$/,'');
    const requestedPlatformRoute=platformRoutePath==='#/platform'||platformRoutePath.startsWith('#/platform/');
    /* v184: the console is fetched only once an admin actually asks for it (see the
       platformConsoleAssets manifest in index.html). Kicked off here, awaited at the point of
       use, so its download overlaps the session and persona round trips instead of following
       them. Everyone who is not an admin never pays for it at all. */
    const platformConsolePromise=requestedPlatformRoute?loadPlatformConsoleAssetsV184():null;
    if(requestedPlatformRoute){
      root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1" aria-labelledby="platformBootTitle">
        <section class="card" style="width:420px;max-width:100%;text-align:center" role="status" aria-live="polite">
          <div class="loader" aria-hidden="true"></div>
          <h1 id="platformBootTitle" style="font-size:1.5rem;margin:14px 0 6px">Opening Peekaa admin</h1>
          <p class="muted small">Checking your access and loading current work…</p>
        </section>
      </main>`;
    }
    if(h.startsWith('#/claim?')){
      const claimRouteParams=new URLSearchParams(h.split('?')[1]||'');
      const invite=claimRouteParams.get('invite')||'';
      if(invite){
        pendingCustomerInvitationToken=invite;
        history.replaceState(null,'',`${location.pathname}${location.search}#/claim`);
        h='#/claim';
      }else if(claimRouteParams.has('business')){
        pendingCustomerBusinessSlug=normalizeCustomerBusinessIntent(claimRouteParams.get('business'));
      }
    }
    if(h.startsWith('#/customer?')){
      const customerRouteParams=new URLSearchParams(h.split('?')[1]||'');
      if(customerRouteParams.has('business')){
        pendingCustomerBusinessSlug=normalizeCustomerBusinessIntent(customerRouteParams.get('business'));
        rememberPendingCustomerDestination('');
      }
    }
    if(h.startsWith('#/join?')){
      const joinParams=new URLSearchParams(h.split('?')[1]||'');
      const joinToken=String(joinParams.get('token')||'').trim();
      rememberPendingCustomerJoinToken(joinToken);
      history.replaceState(null,'',`${location.pathname}${location.search}#/join`);
      h='#/join';
    }
    const {data:{session}}=await sb.auth.getSession();
    if(!isRouteCurrent())return;
    S.user=session?.user||null;
    /* v185: bring in the surface this route renders. The session had to be resolved first, since
       "#/" is the customer entry for a visitor and the workspace for signed-in staff. */
    const appSurfaceV185=appSurfaceForRouteV185(h,{signedIn:!!S.user});
    if(appSurfaceV185)await loadAppChunkV185(appSurfaceV185);
    if(!isRouteCurrent())return;
    globalThis.NestlyCustomerPush?.setAuthenticatedUser?.(S.user?.id||'');
    const recoveryDisposition=customerRecoveryDisposition(customerRecoveryVerified(),S.user?.id||'');
    if(recoveryDisposition==='clear')rememberCustomerRecoveryVerified('');
    if(recoveryDisposition==='require_password'){
      return renderCustomerRecoveryPasswordSetup(isRouteCurrent);
    }
    if(h.startsWith('#/b/')) return renderPortal(h.slice(4).split('?')[0]);
    if(h==='#/'||h==='#/customer'||h==='#/customer/register'||h.startsWith('#/customer?')) return renderCustomerRegistration(isRouteCurrent);
    /* v290 (the road from 8 to 9): a shared offer's in-app landing. Placed BEFORE the
       signed-out guard because the recipient of a shared link is usually a STRANGER — the
       landing resolves the offer anonymously and forwards a signed-out visitor straight to the
       business's public page, never to a sign-in wall. */
    if(h.startsWith('#/offer/'))return renderCustomerOfferLandingV290(decodeURIComponent(h.slice(8).split('?')[0]));
    const directCustomerDestination=normalizeCustomerDestination(h);
    if(!S.user&&directCustomerDestination){
      rememberPendingCustomerDestination(directCustomerDestination);
      pendingCustomerBusinessSlug=directCustomerDestination.startsWith('#/wallet/')
        ?normalizeCustomerBusinessIntent(directCustomerDestination.slice(9))
        :'';
      return renderCustomerRegistration(isRouteCurrent);
    }
    if(!S.user&&h==='#/join')return renderCustomerRegistration(isRouteCurrent);
    if(!S.user&&h==='#/business'&&staffInviteCodeV151)return renderStaffInviteAuthV151('in',staffInviteCodeV151);
    if(!S.user&&h==='#/business'&&new URLSearchParams(location.search).get('signup')==='1')return renderBusinessSignupChoice();
    if(!S.user)return renderAuth('in',{admin:requestedPlatformRoute});
    /* Platform routes are resolved before workspace discovery/onboarding. The platform
       console derives the active role, module rights and sales scope from auth.uid() through
       v89 before it renders navigation or data, so tenant ownership is not required. */
    if(requestedPlatformRoute){
      const platformConsole=await platformConsolePromise;
      if(!isRouteCurrent())return;
      if(typeof platformConsole?.isRoute!=='function'
        ||typeof platformConsole?.render!=='function'
        ||platformConsole.isRoute(h)!==true){
        throw new Error('Peekaa admin could not be loaded. Reload to try again.');
      }
      const workspaceHash=S.biz?.slug
        ?`#/workspace/${encodeURIComponent(S.biz.slug)}/dashboard`
        :'#/';
      return await platformConsole.render({
        root,sb,CUI,brand:BRAND,hash:h,isCurrent:isRouteCurrent,workspaceHash,
        onSignOut:async()=>{
          killChannels();await sb.auth.signOut();resetClientSessionState();nav('#/');
        }
      });
    }
    /* V286: the Stripe self-serve return route, resolved before any persona lookup.
       start_self_serve_business_v130 has already created an active owner staff row by the time
       Stripe redirects here, so every persona-aware branch below would have swallowed this
       route and shown the paying owner a "Complete secure payment" button. */
    if(String(h).split('?')[0]==='#/onboarding/payment')return renderOnboard();
    if(h==='#/business'){
      if(staffInviteCodeV151)return renderBusinessStaffInviteAcceptV151(staffInviteCodeV151);
      const approvedInvite=String(location.search||'').match(/(?:^\?|&)invite=([0-9a-f]{64})(?:&|$)/i)?.[1]?.toLowerCase()||'';
      if(/^[0-9a-f]{64}$/.test(approvedInvite))return renderApprovedBusinessActivation(approvedInvite,isRouteCurrent);
      const {data:businessPersonas,error:businessPersonaError}=await sb.rpc('get_my_personas');
      if(!isRouteCurrent())return;
      if(businessPersonaError)return renderPersonaResolutionUnavailable();
      const staff=sortStaffWorkspaces(businessPersonas?.staff||[]);
      S.staffWorkspaces=staff;
      if(staff.length>1)return renderPersonaChoice(businessPersonas,{includeCustomer:false});
      if(staff.length===1){
        const workspaceRoute=`#/workspace/${encodeURIComponent(staff[0].business_slug)}/dashboard`;
        const preferredRoute=String(businessPersonas?.default_route||'');
        nav(preferredRoute.startsWith('#/workspace/')?preferredRoute:workspaceRoute);
        return;
      }
      return renderOnboard();
    }
    if(h==='#/claim'||h.startsWith('#/claim?')) return renderCustomerClaim();
    if(h==='#/join')return renderCustomerQrJoin();
    if(h==='#/customer/programmes')return renderCustomerProgrammes();
    if(h==='#/customer/bookings')return renderCustomerBookings();
    if(h==='#/customer/explore')return CUSTOMER_EXPLORE_LIVE_V248?renderCustomerExplore():nav('#/wallet');
    if(h==='#/customer/messages')return renderCustomerMessages();
    if(h==='#/customer/profile')return renderCustomerProfile();
    if(h==='#/customer/communications')return renderCustomerCommunicationsV263();
    if(h==='#/wallet'||h.startsWith('#/wallet/')){
      const customerCapabilities=await loadCustomerFeatureCapabilities();
      if(!isRouteCurrent())return;
      if(customerCapabilities._load_error)return renderCustomerCapabilityRetry('We could not check your customer access. Please try again.');
      if(!customerCapabilities.customer_wallet) return renderCustomerWalletUnavailable();
      return renderCustomerWallet(h.startsWith('#/wallet/')?decodeURIComponent(h.slice(9)):null);
    }
    /* V288 (audit A2, HIGH 4). Every workspace route was parsed straight out of the hash, so a
       '?' became part of the page key: '#/appointments?view=list&preset=today' resolved to the
       page 'appointments?view=list&preset=today', matched nothing, and fell back to the
       dashboard. Every deep link with parameters was therefore silently dead. The query is
       split off ONCE here — after the customer/claim/join branches above, which consume their
       own parameters directly from `h` — and kept readable through routeParamV288(). The routes
       reached below never depended on the '?' surviving: they are exact-match page keys. */
    routeQueryParamsV288=new URLSearchParams(String(h).includes('?')?String(h).slice(String(h).indexOf('?')+1):'');
    h=String(h).split('?')[0];
    let workspacePage=null,workspaceStaffPersona=null,resolvedWorkspaceControl=null;
    if(h.startsWith('#/workspace/')){
      const workspaceParts=h.slice(12).split('/');
      const workspaceSlug=decodeURIComponent(workspaceParts[0]||'');
      const requestedModule=decodeURIComponent(workspaceParts[1]||'dashboard');
      const {data:personas,error:personaError}=await sb.rpc('get_my_personas');
      if(!isRouteCurrent())return;
      S.staffWorkspaces=sortStaffWorkspaces(personas?.staff||[]);
      workspaceStaffPersona=!personaError&&(personas?.staff||[]).find(p=>p.business_slug===workspaceSlug);
      if(!workspaceStaffPersona){
        root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="card" style="width:420px;max-width:100%;text-align:center" aria-labelledby="workspaceUnavailableTitle"><h1 id="workspaceUnavailableTitle" style="font-size:1.5rem">Workspace unavailable</h1><p class="muted small" style="margin-top:8px">This workspace is not available to this account.</p><button class="btn" id="workspaceHome" style="margin-top:16px">Continue</button>${accountDeletionCardHtml()}${legalLinks()}</section></main>`;
        $('main').focus();
        wireAccountDeletionButton();
        $('workspaceHome').onclick=()=>nav(personas?.default_route||'#/');return;
      }
      S.hasCustomerPersona=(personas?.customer||[]).length>0?true:null;
      const {data:workspaceGate,error:workspaceGateError}=await sb.rpc(
        'platform_get_business_control_v94',{p_business:workspaceStaffPersona.business_id}
      );
      if(!isRouteCurrent())return;
      if(workspaceGateError||!workspaceGate)return renderPersonaResolutionUnavailable();
      resolvedWorkspaceControl=workspaceGate;
      if(workspaceGate.workspace_access!==true)return renderBusinessWorkspaceControl(workspaceGate);
      const {data:workspace,error:workspaceError}=await sb.from('businesses').select('*').eq('slug',workspaceSlug).single();
      if(!isRouteCurrent())return;
      if(workspaceError||!workspace){
        root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="card" style="width:420px;max-width:100%;text-align:center" aria-labelledby="workspaceUnavailableTitle"><h1 id="workspaceUnavailableTitle" style="font-size:1.5rem">Workspace unavailable</h1><p class="muted small" style="margin-top:8px">This workspace is not available to this account.</p>${accountDeletionCardHtml()}${legalLinks()}</section></main>`;$('main').focus();wireAccountDeletionButton();return;
      }
      if(S.biz?.id!==workspace.id){
        S.biz=workspace;S.myModules=null;S.myModulePerms=null;S.myRole=null;S.isSA=false;S.saChecked=false;S.hasCustomerPersona=null;
      }
      workspacePage=requestedModule;
    }
    if(!S.biz){
      const {data:personas,error:personaError}=await sb.rpc('get_my_personas');
      if(!isRouteCurrent())return;
      if(personaError)return renderPersonaResolutionUnavailable();
      const staff=sortStaffWorkspaces(personas?.staff||[]);
      S.staffWorkspaces=staff;
      if(staff.length){
        const defaultSlug=normalizeCustomerBusinessIntent(String(personas?.default_route||'').match(/#\/workspace\/([^/]+)/)?.[1]||'');
        const selected=staff.find(workspace=>workspace.business_slug===defaultSlug)||staff[0];
        const {data:b,error:businessError}=await sb.from('businesses').select('*').eq('slug',selected.business_slug).single();
        if(!isRouteCurrent())return;
        if(!businessError&&b)S.biz=b;
      }
    }
    if(!S.biz) return renderOnboard();
    /* Approval and subscription access are checked before any module or business data loads.
       Pending/rejected firms and day-14 overdue owners keep an owner-readable contact screen,
       but cannot enter a tenant route or trigger its queries. */
    let workspaceControl=resolvedWorkspaceControl;
    if(!workspaceControl){
      const result=await sb.rpc('platform_get_business_control_v94',{p_business:S.biz.id});
      if(!isRouteCurrent())return;
      if(result.error||!result.data)return renderPersonaResolutionUnavailable();
      workspaceControl=result.data;
    }
    S.biz.quick_earn_catalogue_enabled=workspaceControl.quick_earn_catalogue_enabled!==false;
    if(workspaceControl.workspace_access!==true)return renderBusinessWorkspaceControl(workspaceControl);
    /* Effective module permissions (v14): staff.modules===null means "inherit — sees
       everything the firm enabled"; an explicit array is an allowlist. Owners always
       bypass server-side. Fetched once per session, then cached on S until a Team edit
       resets it back to null (see settingsPage's per-staff module panel). */
    if(S.myModules===null){
      const {data:mm,error:mmErr}=await sb.rpc('get_my_modules',{p_business:S.biz.id});
      if(!isRouteCurrent())return;
      if(mmErr||!mm){
        /* A transient resolver failure must stay fail closed. A workspace route
           already has the effective module list from get_my_personas; legacy
           routes recompute the same v14 precedence from the caller's RLS-scoped
           staff row and never broaden to every firm module by default. */
        const enabled=S.biz.enabled_modules||[];S.isSA=false;
        if(workspaceStaffPersona){
          S.myRole=workspaceStaffPersona.role||null;
          S.myModules=filterResolvedModulesForRole(workspaceStaffPersona.modules,S.myRole);
          S.myModulePerms=Object.fromEntries(S.myModules.map(m=>[m,S.myRole==='owner'?'rw':'r']));
        }else{
          const {data:me}=await sb.from('staff').select('role,modules,module_perms')
            .eq('business_id',S.biz.id).eq('user_id',S.user.id).limit(1);
          if(!isRouteCurrent())return;
          const staffRow=me&&me.length?me[0]:null;
          S.myRole=staffRow?.role||null;
          if(!staffRow){S.myModules=[];S.myModulePerms={}}
          else if(staffRow.role==='owner'){S.myModules=filterResolvedModulesForRole(enabled,staffRow.role);S.myModulePerms=Object.fromEntries(S.myModules.map(m=>[m,'rw']))}
          else if(staffRow.module_perms!==null){S.myModules=filterResolvedModulesForRole(enabled.filter(m=>Object.hasOwn(staffRow.module_perms||{},m)),staffRow.role);S.myModulePerms=Object.fromEntries(S.myModules.map(m=>[m,staffRow.module_perms[m]]))}
          else if(staffRow.modules===null){S.myModules=filterResolvedModulesForRole(enabled,staffRow.role);S.myModulePerms=Object.fromEntries(S.myModules.map(m=>[m,'rw']))}
          else {S.myModules=filterResolvedModulesForRole(enabled.filter(m=>(staffRow.modules||[]).includes(m)),staffRow.role);S.myModulePerms=Object.fromEntries(S.myModules.map(m=>[m,'rw']))}
        }
      }else{
        S.myRole=mm.role||null;S.isSA=mm.is_super_admin===true;
        S.myModules=filterResolvedModulesForRole(mm.modules,S.myRole);
        S.myModulePerms=mm.module_perms&&typeof mm.module_perms==='object'
          ?Object.fromEntries(S.myModules.map(m=>[m,mm.module_perms[m]])):Object.fromEntries(S.myModules.map(m=>[m,'rw']));
      }
    }
    /* get_my_modules resolves staff status and super-admin status server-side. An
       identity with neither an active staff role nor any effective modules must stop
       here: rendering Dashboard would only issue predictable denied data requests. */
    S.saChecked=true;
    const hasResolvedStaffRole=typeof S.myRole==='string'&&S.myRole.length>0;
    const hasResolvedStaffModules=Array.isArray(S.myModules)&&S.myModules.length>0;
    if(!S.isSA&&!hasResolvedStaffRole&&!hasResolvedStaffModules){
      S.myModules=[];S.myModulePerms={};
      return renderWorkspaceAccessUnavailable();
    }
    if(S.hasCustomerPersona===null){
      const {data:personas}=await sb.rpc('get_my_personas');
      if(!isRouteCurrent())return;
      S.staffWorkspaces=sortStaffWorkspaces(personas?.staff||S.staffWorkspaces);
      S.hasCustomerPersona=!!((personas?.customer||[]).length);
      if(!S.hasCustomerPersona){
        const customerCapabilities=await loadCustomerFeatureCapabilities();
        if(!isRouteCurrent())return;
        if(customerCapabilities.customer_phone_registration===true){
          const {data:customerProfile}=await sb.rpc('customer_get_profile');
          if(!isRouteCurrent())return;
          S.hasCustomerPersona=customerProfile?.profile!==null&&customerProfile?.profile!==undefined;
        }
      }
    }
    const frontlineDefault=!workspacePage&&h==='#/'&&['staff','frontdesk'].includes(S.myRole)&&S.myModules.includes('till');
    const page=workspacePage?[workspacePage]:frontlineDefault?['till']:(h.replace('#/','')||'dashboard').split('/');
    if(frontlineDefault)history.replaceState(null,'',`${location.pathname}${location.search}#/till`);
    /* Route guard: a restricted employee must not reach a page by typing the URL, not
       just by it being hidden from nav. 'client' maps to the 'clients' module key, same
       as activeGroupKey() does for the sidebar. dashboard/setup are always reachable. */
    const pageKey=page[0]==='client'?'clients':page[0];
    const growModuleKeys=['loyalty','retention','referrals','memberships','giftcards'];
    if(pageKey==='grow'&&!growModuleKeys.some(module=>canReadModule(module))){
      toast('You don\'t have access to Grow.');
      return nav('#/dashboard');
    }
    /* Settings is owner-only. Hiding the nav link is not a guard — anyone can type the
       hash. The DB is the real boundary (every write in here is RLS/RPC owner-gated), but
       the page also surfaces billing, the team roster and the sign-up QR, so don't render
       it to staff at all. */
    if(pageKey==='settings'&&S.myRole!=='owner'){
      toast('Only the owner can open Settings.');
      return nav('#/dashboard');
    }
    if(pageKey==='branches'&&S.myRole!=='owner'){
      toast('Only the owner can manage branches.');
      return nav('#/dashboard');
    }
    /* V243: same guard as Settings, for the same reason — this page IS the Settings tabs that
       used to be owner-gated, so hiding the rail link is not the boundary. It has no MODULES
       key (it is a surface like Program Studio, not a sector entitlement), so the module guard
       below never sees it and this explicit check is what fails closed for a typed hash. */
    if(pageKey==='customer-interface'&&S.myRole!=='owner'){
      toast('Only the owner can open Customer Interface.');
      return nav('#/dashboard');
    }
    if(pageKey==='setup'&&S.myRole!=='owner'){
      toast('Only the owner can open Get started.');
      return nav('#/dashboard');
    }
    /* Program Studio is owner-only authoring (get_programs_overview is owner-gated). It has no
       MODULES key — it is config authoring like the loyalty/retention editors — so the module
       guard below never sees it; this explicit owner check fails closed for a typed #/studio. */
    if(pageKey==='studio'&&S.myRole!=='owner'){
      toast('Only the owner can open Program Studio.');
      return nav('#/dashboard');
    }
    /* Stored value has no launch-live business authority. Keep the existing foundation and audit
       records, but do not expose its test/cutover controls as an ordinary launch feature. */
    if(pageKey==='storedvalue'){
      toast('Stored value is not available for launch.');
      return nav('#/loyalty');
    }
    /* Promotions are customer-facing publishing authority, not an ordinary staff module.
       Keep the authoring surface owner-only in the client and enforce the same boundary in
       v104 RPCs. Managers/front desk can continue operating the published programme without
       receiving content-publishing authority. */
    if(pageKey==='promotions'&&S.myRole!=='owner'){
      toast('Only the owner can publish promotions.');
      return nav('#/dashboard');
    }
    if(pageKey==='platform'&&!S.isSA){
      toast('Not authorized.');
      return nav('#/dashboard');
    }
    if(HIDDEN_BUSINESS_SURFACES.has(pageKey)){
      toast('This area is not available in the business workspace.');
      return nav('#/dashboard');
    }
    /* V223: hiding the nav link is not a guard — anyone can type the hash. Waitlist is refused
       outright without Bookings, for the same reason it is hidden. */
    if(pageKey==='waitlist'&&!canReadModule('bookings')){
      toast('Waitlist works with Bookings. Turn on Bookings first.');
      return nav('#/dashboard');
    }
    /* V275: the bottle surfaces are exempt from the generic bounce. A non-bar tenant that
       follows a bookmarked #/bottles link gets a plain "not available for this business type"
       card from the page itself; being thrown to the dashboard with a toast reads as a broken
       app rather than as an answer. The page re-checks the sector and the module before it
       renders anything, and the RPCs refuse independently. */
    if(MODULES[pageKey]&&!OWNER_ONLY_MODULES.has(pageKey)&&pageKey!=='dashboard'
       &&!BOTTLE_SURFACES_V275.has(pageKey)
       &&!canReadModule(pageKey)){
      toast('You don\'t have access to that.');
      return nav('#/dashboard');
    }
    if(!isRouteCurrent())return;
    await loadWorkspaceLocaleV97(isRouteCurrent);
    if(!isRouteCurrent())return;
    renderShell(page);
  }catch(e){
    if(!isRouteCurrent())return;
    /* v185 self-heal: if a route reached code that lives in a chunk this render did not load,
       the symbol is simply absent. Rather than show an error for what is a build-time
       classification miss, load both surfaces once and render again. Guarded so a genuine
       ReferenceError inside application code still surfaces on the second pass. */
    if(e instanceof ReferenceError&&!appSurfaceRetriedV185){
      appSurfaceRetriedV185=true;
      console.error('v185 surface miss — loading every surface and retrying',e);
      await Promise.allSettled([loadAppChunkV185('customer'),loadAppChunkV185('business')]);
      if(!isRouteCurrent())return;
      return await route();
    }
    console.error(e);
    root.innerHTML=`<div class="center-wrap"><div class="card" style="width:400px;max-width:100%;text-align:center">
      <div style="font-size:40px">⚠️</div>
      <h2 style="margin:12px 0 4px">Something went wrong</h2>
      <!-- V286: this catch wraps getSession() and the persona RPCs, so a customer on flaky
           mobile data was shown raw engine text ("Failed to fetch"). Same mapper as every
           other failure card in the app. -->
      <p class="muted small">${esc(ownerErrorText(e)||'Please try again.')}</p>
      <button class="btn" id="routeReload" style="margin-top:18px">Reload</button>
      </div></div>`;
    const rb=$('routeReload');
    if(rb) rb.onclick=()=>location.reload();
  }
}

function passwordControlHtml(id,{autocomplete='current-password',minlength='',describedBy='',placeholder='',passkeyButtonId='',locale='en',name=''}={}){
  const showLabel=authSecurityCopy(locale,'showPassword'),hideLabel=authSecurityCopy(locale,'hidePassword');
  const inputAttributes=[
    `id="${esc(id)}"`,`type="password"`,`autocomplete="${esc(autocomplete)}"`,
    /* v193: a password manager pairs a credential from the FIELD NAMES inside a form. Without
       name="password" next to name="username", Chrome and Safari see two anonymous inputs and
       never offer to save. */
    name?`name="${esc(name)}"`:'',
    minlength?`minlength="${esc(minlength)}"`:'',
    describedBy?`aria-describedby="${esc(describedBy)}"`:'',
    placeholder?`placeholder="${esc(placeholder)}"`:''
  ].filter(Boolean).join(' ');
  return `<div class="password-control${passkeyButtonId?' has-passkey':''}"><input ${inputAttributes}>
    <span class="password-control-actions">
      <button class="password-icon-button" type="button" data-password-toggle="${esc(id)}" data-password-show-label="${esc(showLabel)}" data-password-hide-label="${esc(hideLabel)}" aria-controls="${esc(id)}" aria-pressed="false" aria-label="${esc(showLabel)}" title="${esc(showLabel)}">${CUI.icon('eye',{size:20})}</button>
      ${passkeyButtonId?`<button class="password-icon-button" id="${esc(passkeyButtonId)}" type="button" disabled aria-label="${esc(authSecurityCopy(locale,'passkey'))}" title="${esc(authSecurityCopy(locale,'passkeyTitle'))}">${CUI.icon('faceId',{size:21})}</button>`:''}
    </span>
  </div>`;
}
function bindPasswordVisibility(container=document){
  container.querySelectorAll('[data-password-toggle]').forEach(button=>{
    button.onclick=()=>{
      const input=$(button.dataset.passwordToggle);
      if(!input)return;
      const showing=input.type==='text';
      input.type=showing?'password':'text';
      const label=showing?button.dataset.passwordShowLabel:button.dataset.passwordHideLabel;
      button.setAttribute('aria-pressed',String(!showing));
      button.setAttribute('aria-label',label);
      button.title=label;
      button.innerHTML=CUI.icon(showing?'eye':'eyeOff',{size:20});
      input.focus({preventScroll:true});
    };
  });
}
function normalizeSingaporeCustomerPhone(value){
  const digits=String(value??'').replace(/[^0-9]/g,'');
  const local=digits.startsWith('65')&&digits.length===10?digits.slice(2):digits;
  return /^[89][0-9]{7}$/.test(local)?`+65${local}`:null;
}
/* v190 appearance. The customer surface used to go dark whenever the DEVICE was in dark mode, so
   the same person saw a beige workspace and a black wallet on one phone. Beige — the business
   palette — is now the default for everyone, and dark is a choice made in Profile → Appearance.
   'device' remains available for people who genuinely want it to follow their phone. */
const CUSTOMER_THEME_KEY_V190='peekaa.customer.theme';
const CUSTOMER_THEMES_V190=['light','dark','device'];
function customerThemePreferenceV190(){
  try{
    const stored=localStorage.getItem(CUSTOMER_THEME_KEY_V190);
    return CUSTOMER_THEMES_V190.includes(stored)?stored:'light';
  }catch{return 'light'}
}
function customerThemeIsDarkV190(preference=customerThemePreferenceV190()){
  if(preference==='dark')return true;
  if(preference!=='device')return false;
  try{return globalThis.matchMedia?.('(prefers-color-scheme: dark)').matches===true}catch{return false}
}
function applyCustomerThemeV190(preference=customerThemePreferenceV190()){
  const root=globalThis.document?.documentElement;
  if(!root)return preference;
  const dark=customerThemeIsDarkV190(preference);
  if(dark)root.setAttribute('data-customer-theme','dark');
  else root.removeAttribute('data-customer-theme');
  /* Keep the browser chrome with the surface rather than with the device. */
  const meta=globalThis.document?.querySelector('meta[name="theme-color"]:not([media])');
  if(meta)meta.setAttribute('content',dark?'#0F1115':'#F4F2EE');
  return preference;
}
/* A device-following customer must track a change made while the app is open. */
try{globalThis.matchMedia?.('(prefers-color-scheme: dark)')?.addEventListener?.('change',()=>{
  if(customerThemePreferenceV190()==='device')applyCustomerThemeV190('device');
})}catch{}
function setCustomerSurfaceDocumentV167(){
  globalThis.document?.documentElement?.setAttribute('data-customer-surface','true');
  applyCustomerThemeV190();
}
const CUSTOMER_LOCALES=Object.freeze(['en']);
const CUSTOMER_COPY=Object.freeze({
  en:Object.freeze({
    home:'Home',programmes:'My Rewards',rewardsTab:'Rewards',explore:'Explore',bookings:'Bookings',scanQr:'Scan QR',profileTab:'Profile',
    notifications:'Notifications',accountMenu:'Open account menu',profilePasskeys:'Profile & passkeys',signOut:'Sign out',
    language:'Language',english:'English',chinese:'简体中文',backProgrammes:'Back to My Rewards',
    chooseProgramme:'Choose a reward business',yourProgrammes:'My Rewards',
    programmesIntro:'Pick a business to open its rewards, benefits, bookings and activity.',
    addProgramme:'Scan to join',openProgramme:'Open {business} rewards',localBusiness:'Local business',
    rewardReady:'Reward ready — open to redeem.',continueProgramme:'Open your rewards home to see what is next.',
    firstQuest:'Your first rewards',scanLoyaltyQr:'Scan a loyalty QR',
    firstQuestBody:'At a participating business, scan the Peekaa QR shown at the counter. That verified business becomes your first reward account.',
    scanBusinessQr:'Scan business QR',qrOnlyHelp:'Businesses can only be added with a business-issued QR.',
    balance:'Balance',nextReward:'Next reward',tierProgress:'Tier progress',benefits:'Benefits & perks',
    offers:'Birthday & seasonal offers',rewards:'Rewards',activityHistory:'Activity & history',
    noBenefits:'No extra perks are available right now.',noOffers:'No birthday or seasonal offers are available right now.',
    noRewards:'No rewards are available right now.',
    retry:'Try again',bookNow:'Book now',requestVisit:'Request your next visit with {business}.',
    points:'points',stamps:'stamps',currentTier:'Current tier',nextTier:'Next: {tier}',
    terms:'Terms',availableNow:'Available now',
    loadingProgramme:'Loading rewards…',loadingProgrammes:'Loading My Rewards…',
    successSounds:'Success sounds',soundOff:'Off by default',soundOn:'On',
    soundHelp:'Optional. Sounds stay off when reduced motion is requested.',
    merchantProgramme:'{business} rewards',featured:'Featured products & services',
    noFeatured:'This business has not published featured items yet.'
  })
});
let customerLocale='en';
function ct(key,vars={}){
  let value=CUSTOMER_COPY[customerLocale]?.[key]??CUSTOMER_COPY.en[key]??key;
  for(const [name,replacement] of Object.entries(vars))value=value.replaceAll(`{${name}}`,String(replacement??''));
  return value;
}
function customerMediaUrlV95(value){
  const raw=String(value||'').trim();
  if(!raw)return '';
  const publicPrefix='/storage/v1/object/public/business-public/';
  const objectPathPattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\/(?:logo|hero|programme|reward|product|service|benefit|offer)\/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(?:png|jpe?g|webp|gif)$/i;
  const origin=SB_URL.replace(/\/+$/,'');
  const relative=raw.startsWith(publicPrefix)?raw.slice(publicPrefix.length):'';
  if(relative&&objectPathPattern.test(relative))return origin+raw;
  const absolutePrefix=origin+publicPrefix;
  const absolutePath=raw.startsWith(absolutePrefix)?raw.slice(absolutePrefix.length):'';
  if(absolutePath&&objectPathPattern.test(absolutePath))return raw;
  return '';
}
/* v194: the nav is painted before the wallet data arrives, so the counts are remembered and
   re-applied in place once they resolve. A stale count is never shown as fresh — see
   applyCustomerNavCountsV194, which repaints the badges the moment the real numbers land. */
let customerNavCountsV194={programmes:0,bookings:0};
/* v195 (owner circled Scan QR and drew it up beside the bell): scanning is an ACTION, not a
   destination — it opens the camera and returns you to where you were. Sitting in the tab bar it
   claimed a quarter of the navigation and read like a fourth page. It is now the header control
   next to notifications, on every customer screen, and the nav holds only real destinations. */
/* v248 (owner: "just hide the explore button entire (so will not shown to customers)"): Explore
   is not offered at all for now — no tab, and the route refuses rather than rendering a page a
   customer has no way to reach. The search below is finished, shipped and tested (v245 catalogue
   search, v247 nearest-first); this ONE constant is the whole switch, so nothing is deleted,
   nothing is half-wired, and turning it on restores the tab and the route together. */
const CUSTOMER_EXPLORE_LIVE_V248=false;
/* v244 (owner, Grab-style reference screenshot): five slots — Home · Rewards · Scan · Explore ·
   Bookings — with Scan as the raised centre control. Scan returned to the nav from the header
   because the reference makes it the app's signature action, not a corner utility; it is still
   the same openCustomerJoinScanner behind the same id. Explore is new: search the whole Peekaa
   ecosystem ("chicken rice", "food near me") the way you'd search Google. */
/* v281 (owner: "change it to scan in the middle and add a profile module at the most right. so 2
   left 1 qrcode scanning"): five slots — Home · Rewards on the left, Scan as the raised centre,
   Bookings · Profile on the right. Profile was reachable only through the header avatar menu, two
   taps behind an icon; the owner promoted it to a first-class destination. The route and page
   (#/customer/profile, renderCustomerProfile) already existed — only this entry is new. */
const CUSTOMER_PRIMARY_NAV=Object.freeze([
  {key:'home',href:'#/wallet',icon:'home',copy:'home'},
  {key:'programmes',href:'#/customer/programmes',icon:'loyalty',copy:'rewardsTab'},
  {key:'scan',icon:'scan',copy:'scanQr'},
  ...(CUSTOMER_EXPLORE_LIVE_V248?[{key:'explore',href:'#/customer/explore',icon:'search',copy:'explore'}]:[]),
  {key:'bookings',href:'#/customer/bookings',icon:'bookings',copy:'bookings'},
  {key:'profile',href:'#/customer/profile',icon:'customers',copy:'profileTab'}
]);
/* v194 (owner: "put number to show how many valid rewards i have — here also" on Bookings): the
   two tabs that hold countable things now carry that count. A zero is not rendered — a badge
   reading 0 is noise, and the tab already says what it holds. */
function customerPrimaryNavigation(active,counts={}){
  const badge=key=>{
    const value=Math.max(0,Number(counts?.[key])||0);
    return value?`<span class="customer-nav-count" aria-hidden="true">${value>99?'99+':value}</span>`:'';
  };
  const label=(item)=>{
    const value=Math.max(0,Number(counts?.[item.key])||0);
    const text=ct(item.copy);
    return value?`${text}, ${value}`:text;
  };
  return `<nav class="customer-primary-nav" aria-label="${esc(BRAND.customerLabel)}">
    ${CUSTOMER_PRIMARY_NAV.map(item=>item.key==='scan'
      ?`<button type="button" id="customerNavScan" class="customer-nav-scan" aria-label="${esc(ct(item.copy))}"><span class="customer-nav-scan-fab">${CUI.icon(item.icon,{size:22})}</span><span>${esc(ct(item.copy))}</span></button>`
      :`<a href="${item.href}"${item.key===active?' aria-current="page"':''} aria-label="${esc(label(item))}">${CUI.icon(item.icon,{size:19})}<span>${esc(ct(item.copy))}</span>${badge(item.key)}</a>`).join('')}
  </nav>`;
}
function customerJoinTokenFromQr(value,currentUrl=location.href){
  const raw=String(value??'').trim();
  if(!raw)return '';
  if(/^[A-Za-z0-9_-]{20,512}$/.test(raw))return raw;
  try{
    const url=new URL(raw,currentUrl);
    const hashParams=new URLSearchParams((url.hash.split('?')[1]||''));
    const token=url.searchParams.get('token')||hashParams.get('token')||'';
    return /^[A-Za-z0-9_-]{20,512}$/.test(token)?token:'';
  }catch{return ''}
}
let activeCustomerJoinScannerCleanup=()=>{};
function openCustomerJoinScanner(){
  activeCustomerJoinScannerCleanup();
  const overlay=document.createElement('div');
  overlay.className='modal customer-surface appointment-detail-modal customer-scan-modal';
  overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');
  overlay.setAttribute('aria-labelledby','customerJoinScannerTitle');
  /* v281 (owner: "must show scan, currently need to choose to upload or scan, just show scan
     first"): the camera starts the moment the sheet opens — tapping Scan IS the consent to scan,
     so a second "Open camera" tap was pure friction. The upload/paste fallbacks still exist (a
     desktop with no camera, a screenshot of a QR) but they wait hidden behind one small control,
     and reveal themselves automatically the moment the camera cannot start. */
  overlay.innerHTML=`<section class="modal-card"><div class="row"><div><p class="customer-quest-kicker">Add rewards</p><h2 id="customerJoinScannerTitle" style="margin-top:5px">Scan the business QR</h2><p class="muted small" style="margin-top:5px">Use the Peekaa QR displayed by the business. A scan never joins an unrelated business.</p></div><span class="spacer"></span><button class="btn ghost sm" id="customerJoinScannerClose" type="button" aria-label="Close scanner">${CUI.icon('close',{size:18})}</button></div>
    <div class="scanner-frame" id="customerJoinScannerFrame" hidden><video class="scanner-video" id="customerJoinScannerVideo" playsinline muted aria-label="Camera preview for business join QR"></video></div>
    <button class="btn" id="customerJoinScannerCamera" type="button" style="width:100%;margin-top:16px" hidden>${CUI.icon('scan',{size:18})}<span>Open camera</span></button>
    <p id="customerJoinScannerStatus" class="muted small" role="status" aria-live="polite" style="margin-top:12px"></p>
    <button class="btn ghost sm" id="customerJoinScannerManual" type="button" style="width:100%;margin-top:12px">Can't scan? Use a photo or link</button>
    <div class="scanner-fallback" id="customerJoinScannerFallback" hidden><label for="customerJoinScannerImage">Or choose a QR image</label><input id="customerJoinScannerImage" type="file" accept="image/*">
      <details id="customerJoinScannerPaste" style="margin-top:12px"><summary class="small">Camera unavailable?</summary><label for="customerJoinScannerValue">Paste the QR link</label><input id="customerJoinScannerValue" type="url" autocomplete="off" spellcheck="false"><button class="btn ghost sm" id="customerJoinScannerConfirm" type="button" style="margin-top:10px">Continue</button></details>
    </div></section>`;
  document.body.appendChild(overlay);
  const video=overlay.querySelector('#customerJoinScannerVideo');
  const frame=overlay.querySelector('#customerJoinScannerFrame');
  const status=overlay.querySelector('#customerJoinScannerStatus');
  const camera=overlay.querySelector('#customerJoinScannerCamera');
  const imageInput=overlay.querySelector('#customerJoinScannerImage');
  const pasteFallback=overlay.querySelector('#customerJoinScannerPaste');
  const fallbackWrap=overlay.querySelector('#customerJoinScannerFallback');
  const manualToggle=overlay.querySelector('#customerJoinScannerManual');
  const canvas=document.createElement('canvas'),context=canvas.getContext('2d',{willReadFrequently:true});
  let stream=null,frameHandle=0,closed=false,dialogCleanup=()=>{};
  const stop=()=>{if(frameHandle)cancelAnimationFrame(frameHandle);frameHandle=0;if(stream)stream.getTracks().forEach(track=>track.stop());stream=null;if(video)video.srcObject=null};
  const close=({restoreFocus=true}={})=>{if(closed)return;closed=true;stop();dialogCleanup({restoreFocus});if(activeCustomerJoinScannerCleanup===close)activeCustomerJoinScannerCleanup=()=>{}};
  activeCustomerJoinScannerCleanup=close;
  const accept=value=>{
    const token=customerJoinTokenFromQr(value);
    if(!token){status.textContent='That is not an active Peekaa business QR. Ask the business to generate its latest join QR.';return false}
    rememberPendingCustomerJoinToken(token);close({restoreFocus:false});
    /* v281 audit: a rescan from the expired-QR screen is ALREADY at #/join — same-hash nav()
       fires nothing, so the new token was remembered and never submitted. */
    if(location.hash==='#/join')route();else nav('#/join');
    return true;
  };
  const decode=(source,width,height)=>{
    if(typeof globalThis.jsQR!=='function'||!context||!width||!height)return '';
    canvas.width=width;canvas.height=height;context.drawImage(source,0,0,width,height);
    return globalThis.jsQR(context.getImageData(0,0,width,height).data,width,height)?.data||'';
  };
  const scan=()=>{
    if(closed||!stream)return;
    if(video.readyState>=2&&accept(decode(video,video.videoWidth,video.videoHeight)))return;
    frameHandle=requestAnimationFrame(scan);
  };
  /* Reveals the photo/paste alternatives. On camera failure this is called automatically so the
     customer is never stranded at a dead camera frame; the paste path opens too because a
     desktop user with no camera most often HAS the link. */
  const revealFallback=()=>{
    fallbackWrap.hidden=false;manualToggle.hidden=true;
    pasteFallback.open=true;imageInput.focus();
  };
  /* v286 (audit): loadScannerLibrary pulls jsQR from a CDN, so a blocked CDN, an SRI mismatch or
     an offline device used to reject inside the SAME catch as getUserMedia and be reported as
     'Camera access was not available' — a lie about a camera that was never even asked for, and
     the advice it gave (use a photo) led into the photo path, which needs the same missing
     decoder and then blamed the customer's picture. The loader now has its own guard on BOTH
     decoder paths and reports the real failure, with the camera button left as a live retry. */
  const DECODER_LOAD_FAILURE='The scanner could not load. Check your connection and try again.';
  const cameraLabel=camera.querySelector('span');
  const loadDecoder=async()=>{try{await loadScannerLibrary();return true}catch{return false}};
  const startCamera=async()=>{
    if(closed)return;
    if(!navigator.mediaDevices?.getUserMedia){status.textContent='Camera is unavailable in this browser. Choose a QR image or paste the QR link.';revealFallback();return}
    camera.disabled=true;camera.hidden=true;status.textContent='Starting camera…';
    if(!await loadDecoder()){
      if(closed)return;
      camera.disabled=false;camera.hidden=false;if(cameraLabel)cameraLabel.textContent='Try again';
      status.textContent=DECODER_LOAD_FAILURE;return;
    }
    if(cameraLabel)cameraLabel.textContent='Open camera';
    try{
      stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:{ideal:'environment'}},audio:false});
      if(closed){stream.getTracks().forEach(track=>track.stop());stream=null;return}
      video.srcObject=stream;frame.hidden=false;await video.play();status.textContent='Point the camera at the business QR.';scan();
    }catch{
      if(closed)return;
      camera.disabled=false;camera.hidden=false;
      status.textContent='Camera access was not available. Choose a QR image or paste the QR link.';revealFallback();
    }
  };
  camera.onclick=startCamera;
  manualToggle.onclick=()=>revealFallback();
  imageInput.onchange=async event=>{
    const file=event.target.files?.[0];if(!file)return;
    status.textContent='Reading QR image…';
    /* v286: the photo path needs the same CDN decoder, so it reports the same honest failure
       instead of 'That image could not be read' — the image was never the problem. */
    if(!await loadDecoder()){status.textContent=DECODER_LOAD_FAILURE;return}
    try{
      const bitmap=await createImageBitmap(file);
      const value=decode(bitmap,bitmap.width,bitmap.height);bitmap.close?.();
      if(!accept(value))status.textContent='No active Peekaa join QR was found in that image.';
    }catch{status.textContent='That image could not be read. Try a clearer QR image.'}
  };
  const pasteValue=overlay.querySelector('#customerJoinScannerValue');
  overlay.querySelector('#customerJoinScannerConfirm').onclick=()=>accept(pasteValue.value);
  /* v286 (audit): the paste field lives in no <form>, so there was no implicit submission and
     Enter — the universal reflex, and the only keyboard path — did nothing, silently. */
  pasteValue.onkeydown=event=>{if(event.key==='Enter'){event.preventDefault();accept(pasteValue.value)}};
  overlay.querySelector('#customerJoinScannerClose').onclick=close;
  overlay.addEventListener('click',event=>{if(event.target===overlay)close()});
  dialogCleanup=CUI.activateDialog(overlay,{onClose:close,initialFocus:'#customerJoinScannerClose'});
  startCamera();
}
function sortStaffWorkspaces(staff){
  return [...(Array.isArray(staff)?staff:[])].sort((a,b)=>{
    const byName=String(a?.business_name||'').localeCompare(String(b?.business_name||''),undefined,{sensitivity:'base'});
    return byName||String(a?.business_slug||'').localeCompare(String(b?.business_slug||''));
  });
}
function customerWorkspaceSwitchHtml(staffWorkspaces=[]){
  const workspaces=sortStaffWorkspaces(staffWorkspaces);
  if(!workspaces.length)return '';
  if(workspaces.length===1){
    const workspace=workspaces[0];
    const name=workspace.business_name||workspace.business_slug||'Business';
    return `<a class="btn ghost sm" href="#/workspace/${encodeURIComponent(workspace.business_slug)}/dashboard" aria-label="Open ${esc(name)} staff workspace">${CUI.icon('branch',{size:17})}<span>${esc(name)} workspace</span></a>`;
  }
  return `<details class="customer-workspace-switch"><summary class="btn ghost sm" aria-label="Open ${workspaces.length} authorized staff workspaces">${CUI.icon('branch',{size:17})}<span>Business workspaces (${workspaces.length})</span></summary><div class="menu" aria-label="Authorized staff workspaces">${workspaces.map(workspace=>`<a href="#/workspace/${encodeURIComponent(workspace.business_slug)}/dashboard">${esc(workspace.business_name||workspace.business_slug)}</a>`).join('')}</div></details>`;
}
function renderNoCustomerDestination(staffWorkspaces=[]){
  const workspaces=sortStaffWorkspaces(staffWorkspaces);
  const relationshipRetry=customerRelationshipSyncCanRecover();
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="card" style="width:520px;max-width:100%" aria-labelledby="noCustomerTitle">
    <div class="logo">${brandWordmark()}</div><h1 id="noCustomerTitle" style="font-size:1.55rem;margin-top:16px">${esc(BRAND.customerLabel)} is not set up for this account</h1>
    <p class="muted" style="margin-top:7px;line-height:1.55">This signed-in account has staff access, but no registered customer profile or linked customer programme. No empty wallet has been shown.</p>
    ${relationshipRetry?`<div class="row" style="margin-top:16px">${customerRelationshipCheckActionHtml()}</div>`:''}
    ${workspaces.length?`<div style="margin-top:16px"><b>Open a staff workspace</b><div class="row" style="margin-top:10px">${workspaces.map(workspace=>`<a class="btn ghost sm" href="#/workspace/${encodeURIComponent(workspace.business_slug)}/dashboard">${esc(workspace.business_name||workspace.business_slug)}</a>`).join('')}</div></div>`:''}
    <a class="btn" href="#/customer" style="margin-top:18px">Set up ${esc(BRAND.customerLabel)}</a>
    ${legalLinks()}</section></main>`;
  if(relationshipRetry)wireCustomerRelationshipCheck(()=>route());
  CUI.focusRoute($('main'),{enhanceContent:true});
}
function customerSurfaceQualifies(profile,customerPersonas=[]){
  return (profile!==null&&profile!==undefined)||(Array.isArray(customerPersonas)&&customerPersonas.length>0);
}
let customerAccountMenuCleanup=()=>{};
function wireCustomerAccountMenu(){
  customerAccountMenuCleanup();
  const customerAccountMenuDetails=document.querySelector('.customer-account-menu');
  if(!customerAccountMenuDetails)return;
  const summary=customerAccountMenuDetails.querySelector('summary');
  const onPointerDown=event=>{
    if(customerAccountMenuDetails.open&&!customerAccountMenuDetails.contains(event.target))customerAccountMenuDetails.open=false;
  };
  const onKeyDown=event=>{
    if(event.key==='Escape'&&customerAccountMenuDetails.open){
      event.preventDefault();customerAccountMenuDetails.open=false;summary?.focus();
    }
  };
  document.addEventListener('pointerdown',onPointerDown);
  document.addEventListener('keydown',onKeyDown);
  customerAccountMenuCleanup=()=>{
    document.removeEventListener('pointerdown',onPointerDown);
    document.removeEventListener('keydown',onKeyDown);
    customerAccountMenuCleanup=()=>{};
  };
}
/* v178: backTo generalises the business-page circle back button so the "My Rewards" tab can
   carry one too (owner: "There is no back button"). businessSlug keeps its own destination. */
function renderCustomerShell({active='home',body='',businessSlug=null,staffWorkspaces=[],messagesAvailable=null,backTo=null,navCounts=null}={}){
  setCustomerSurfaceDocumentV167();
  globalThis.document?.documentElement?.setAttribute('lang','en');
  const inboxAvailable=messagesAvailable===null?customerInboxEnabledV178===true:messagesAvailable===true,
    backHref=businessSlug?'#/customer/programmes':(backTo||''),
    backLabel=businessSlug?ct('backProgrammes'):'Back to home';
  root.innerHTML=`<div class="wallet-shell customer-shell customer-surface"><div class="wallet-inner"><header class="wallet-head">
    ${backHref?`<button class="btn ghost sm" id="walletBack" aria-label="${esc(backLabel)}" style="min-width:44px">${CUI.icon('back',{size:18})}</button>`:''}
    <a class="logo" href="#/wallet" aria-label="${esc(BRAND.customerLabel)} home">${brandWordmark()}</a>
    <span class="spacer"></span><span id="customerInboxBellSlot">${inboxAvailable?`<a class="customer-inbox-bell" href="#/customer/messages" aria-label="${esc(ct('notifications'))}" title="${esc(ct('notifications'))}">${CUI.icon('bell',{size:19})}</a>`:''}</span>
    ${customerWorkspaceSwitchHtml(staffWorkspaces)}
    <details class="customer-account-menu"><summary class="customer-avatar" aria-label="${esc(ct('accountMenu'))}">${CUI.icon('customers',{size:20})}</summary><div class="menu">
      <a href="#/customer/profile">${CUI.icon('customers',{size:17})}<span>${esc(ct('profilePasskeys'))}</span></a>
      <button id="customerPushMenuControl" type="button" aria-pressed="false">${CUI.icon('bell',{size:17})}<span data-push-label>Turn on device notifications</span></button>
      <button id="walletSignOut" type="button">${CUI.icon('back',{size:17})}<span>${esc(ct('signOut'))}</span></button>
    </div></details>
    </header>${customerPrimaryNavigation(active,navCounts||customerNavCountsV194)}
    <main id="main" tabindex="-1"><div id="walletBody">${body}</div></main>
    ${legalLinks()}</div></div>`;
  $('walletSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
  const customerPush=window.NestlyCustomerPush?.configure({rpc:(name,args)=>sb.rpc(name,args),userId:S.user?.id});
  if(customerPush){
    customerPush.bindButton($('customerPushMenuControl'));
    customerPush.reconcile().catch(()=>{});
  }
  wireCustomerAccountMenu();
  if($('customerNavScan'))$('customerNavScan').onclick=openCustomerJoinScanner;
  if($('walletBack'))$('walletBack').onclick=()=>nav(backHref);
}
function focusCustomerRoute(){
  const main=$('main');if(main)CUI.focusRoute(main,{enhanceContent:true});
  if(S.user&&typeof completePendingCustomerDestination==='function')completePendingCustomerDestination(location.hash);
}
async function syncVerifiedCustomerRelationshipsOnce(isCurrent=()=>true){
  const userId=S.user?.id||null;
  if(!userId)return {attempted:false,linked:false};
  if(customerRelationshipSyncState.userId!==userId){
    customerRelationshipSyncState={userId,attempted:false,result:null};
  }
  if(customerRelationshipSyncState.attempted){
    const result=customerRelationshipSyncState.result;
    return {
      attempted:true,linked:Number(result?.linked_count||0)>0,result,
      backendNotApplied:result?.outcome==='backend_not_applied'
    };
  }
  const {data,error}=await sb.rpc('customer_sync_verified_relationships_v81',{
    p_idempotency_key:crypto.randomUUID()
  });
  if(!isCurrent())return {attempted:false,linked:false,stale:true};
  if(error){
    // A build can safely run before v81 is applied. Missing-function responses must
    // preserve the earlier explicit-claim wallet instead of turning it into an error.
    if(error.code==='PGRST202'||error.code==='42883'){
      customerRelationshipSyncState.attempted=true;
      customerRelationshipSyncState.result={outcome:'backend_not_applied'};
      return {attempted:true,linked:false,backendNotApplied:true};
    }
    // Transport, gateway and RPC failures are recoverable. Do not memoize them as
    // a completed session attempt: the empty/destination state exposes a retry.
    customerRelationshipSyncState.attempted=false;
    customerRelationshipSyncState.result={outcome:'try_later'};
    return {attempted:false,linked:false,error,retryable:true};
  }
  customerRelationshipSyncState.attempted=true;
  customerRelationshipSyncState.result=data||{outcome:'synchronized',linked_count:0};
  return {attempted:true,linked:Number(data?.linked_count||0)>0,result:data};
}
function customerRelationshipSyncCanRecover(){
  return customerRelationshipSyncState.attempted===false
    &&customerRelationshipSyncState.result?.outcome==='try_later';
}
function customerRelationshipCheckActionHtml(){
  const retry=customerRelationshipSyncCanRecover();
  return `${retry?'<span class="muted small" id="customerRelationshipRetryHelp" role="status">We could not complete the last programme check. Your account is unchanged.</span>':''}<button class="btn ghost sm" id="customerRelationshipCheck" type="button"${retry?' aria-describedby="customerRelationshipRetryHelp"':''}>${retry?'Retry programme check':'Check for existing programmes'}</button>`;
}
function wireCustomerRelationshipCheck(renderer){
  const button=$('customerRelationshipCheck');
  if(!button)return;
  button.onclick=()=>{
    const userId=S.user?.id||null;
    customerRelationshipSyncState={userId,attempted:false,result:null};
    button.disabled=true;button.textContent='Checking…';
    CUI.announce('Checking for existing programmes.');
    renderer();
  };
}
/* v178: the header bell is a first-class shell control, so every customer shell — including the
   QR-join screens that render before a route context exists — reads the same resolved flag. */
let customerInboxEnabledV178=false;
async function loadCustomerSurfaceContext(isCurrent=()=>true){
  const features=await loadCustomerFeatureCapabilities();
  customerInboxEnabledV178=features?.customer_in_app_inbox===true;
  if(!isCurrent())return null;
  if(features._load_error){renderCustomerCapabilityRetry('We could not check your customer access. Please try again.');return null}
  if(!features.customer_wallet){renderCustomerWalletUnavailable();return null}
  const [profileResult,personaResult]=await Promise.all([
    features.customer_phone_registration===true?customerRpc('customer_get_profile'):Promise.resolve({data:null,error:null}),
    customerRpc('get_my_personas')
  ]);
  if(!isCurrent())return null;
  let {data:personas,error:personasError}=personaResult;
  if(personasError){renderCustomerCapabilityRetry('We could not load your customer destinations. Please try again.');return null}
  let staff=sortStaffWorkspaces(personas?.staff||[]),customer=personas?.customer||[];
  if(profileResult.error&&!customer.length){
    renderCustomerCapabilityRetry('We could not load your customer profile. Please try again.');return null;
  }
  const profile=profileResult.error?null:(profileResult.data?.profile??null);
  const registeredCustomer=profile!==null;
  if(!customerSurfaceQualifies(profile,customer)){renderNoCustomerDestination(staff);return null}
  S.hasCustomerPersona=true;S.customerProfile=profile;
  customerLocale='en';
  globalThis.document?.documentElement?.setAttribute('lang','en');
  if(!isCurrent())return null;
  /* v286: a null profile has two very different causes — this account has no profile row, or
     customer_get_profile just failed for a customer we kept on the surface because their personas
     loaded. Carry the error so callers can say which one happened instead of blaming the account. */
  return {features,profile,profileError:profileResult.error||null,registeredCustomer,staff,customer,staffWorkspaces:staff};
}

/* v244 (owner, nav revamp): Explore — "search for nearby peekaa businessess (can type example
   food near me, chicken rice, dessert shop etc) - then will pop up relevant business based on
   search - like google search)". The matching runs on the SERVER, because "chicken rice" should
   find a business that SELLS chicken rice — a fact only the catalogue knows — not just one named
   after it. The empty query is the whole ecosystem, joined businesses first, which is the v242
   directory the owner already approved; it lives here now, behind its own tab, instead of at the
   bottom of Home. */
/* v247 (owner: "add the geocoding + nearest first sorting"): a distance is only ever printed when
   the SERVER computed one from a real geocoded branch. A business with no location shows nothing
   here rather than a guess, and it still appears in the list — being unlocated is the owner's
   admin gap, not a reason to hide a business the customer may already belong to. */
function customerExploreDistanceTextV247(km){
  /* Number(null) and Number('') are both 0, which would print "50 m" for a business whose
     location is simply UNKNOWN — the exact fabrication this function exists to prevent. Only a
     real number counts as a distance. */
  if(typeof km!=='number'&&typeof km!=='string')return '';
  if(typeof km==='string'&&!km.trim())return '';
  const value=Number(km);
  if(!Number.isFinite(value)||value<0)return '';
  if(value<1)return `${Math.max(50,Math.round(value*1000/50)*50)} m`;
  return `${value<10?value.toFixed(1):Math.round(value)} km`;
}
function customerExploreRowMarkupV244(row){
  const name=String(row?.name||'').trim()||'Business',industry=String(row?.industry||'').trim(),
    joined=row?.joined===true,slug=String(row?.slug||''),
    logo=customerMediaUrlV95(row?.logo_url),
    address=String(row?.address||'').trim(),
    match=String(row?.match_note||'').trim(),
    distance=customerExploreDistanceTextV247(row?.distance_km),
    points=Math.max(0,Number(row?.points_balance||0)),
    initial=(name[0]||'B').toUpperCase();
  const media=logo
    ?`<img class="customer-explore-logo" src="${esc(logo)}" alt="" loading="lazy" width="46" height="46">`
    :`<span class="customer-explore-logo customer-explore-logo--fallback" aria-hidden="true">${esc(initial)}</span>`;
  const copy=`<div class="customer-explore-copy">
      <h3 data-merchant-content>${esc(name)}</h3>
      ${industry?`<p class="muted small" data-merchant-content>${esc(industry)}</p>`:''}
      ${match?`<p class="small customer-explore-match">Has: ${esc(match)}</p>`:''}
      ${address||distance?`<p class="muted small customer-explore-address">${distance?`<span class="customer-explore-distance">${esc(distance)}</span>`:''}${address?`<span data-merchant-content>${esc(address)}</span>`:''}</p>`:''}
    </div>`;
  const side=joined
    ?`<div class="customer-explore-side"><span class="pill ok">Member</span><b>${esc(customerPointTotalV103(points))}</b><span class="muted small">points</span></div>`
    :`<div class="customer-explore-side"><span class="pill off">Not set up</span><span class="muted small customer-explore-join-hint">Scan their QR in store to join</span></div>`;
  /* Joined rows use the one existing route into a business. An unjoined row deliberately does
     not navigate — v242's rule: the shop's own QR is the only way in. */
  return joined
    ?`<a class="card customer-explore-row" href="#/wallet/${encodeURIComponent(slug)}">${media}${copy}${side}</a>`
    :`<div class="card customer-explore-row customer-explore-row--locked">${media}${copy}${side}</div>`;
}
function customerExploreResultsMarkupV244(state){
  if(state.status==='loading')return '<div class="card customer-explore-state" aria-busy="true"><p class="muted small">Searching…</p></div>';
  if(state.status==='error')return '<div class="card customer-explore-state"><p class="muted small">Businesses couldn’t load.</p><button class="btn ghost sm" id="customerExploreRetry" type="button" style="margin-top:10px">Try again</button></div>';
  const seen=new Set(),rows=(Array.isArray(state.rows)?state.rows:[]).filter(row=>{
    const id=String(row?.business_id||'');
    if(!id||seen.has(id))return false;
    seen.add(id);return true;
  });
  if(!rows.length)return state.query
    ?`<div class="card customer-explore-state"><p class="muted small">Nothing matches “${esc(state.query)}”. Try a food, a service, or a shop name.</p></div>`
    :'<div class="card customer-explore-state"><p class="muted small">No businesses to show yet.</p></div>';
  /* When the customer shared a position, say so — and say plainly how many businesses could not be
     ranked, because a list that silently mixes "2 km away" with "somewhere unknown" is misleading. */
  const unlocated=state.near?rows.filter(row=>row?.located!==true).length:0;
  const order=state.near
    ?`<p class="muted small customer-explore-order">${CUI.icon('bookings',{size:14})} Nearest first${unlocated?` · ${unlocated} ${unlocated===1?'business has':'businesses have'} no address yet, shown last`:''}</p>`
    :'';
  return `${order}<div class="customer-explore-list">${rows.map(customerExploreRowMarkupV244).join('')}</div>
    <p class="muted small customer-explore-note">Points and rewards are separate for every business.</p>`;
}
async function renderCustomerExplore(){
  const walletRenderEpoch=++customerWalletRenderEpoch,isCurrent=()=>customerWalletRenderEpoch===walletRenderEpoch;
  const context=await loadCustomerSurfaceContext(isCurrent);if(!context)return;
  renderCustomerShell({active:'explore',staffWorkspaces:context.staffWorkspaces,messagesAvailable:context.features.customer_in_app_inbox===true,
    body:`<header class="customer-page-head"><div><h1>Explore</h1><p class="muted small">Every business on Peekaa — find one by what it sells.</p></div></header>
    <div class="customer-explore-search"><label class="sr-only" for="customerExploreQuery">Search businesses</label>
      ${CUI.icon('search',{size:18})}<input id="customerExploreQuery" type="search" autocomplete="off" enterkeyhint="search" placeholder="Try “chicken rice”, “facial”, “dessert”…"></div>
    <div class="customer-explore-tools"><button class="btn ghost sm" id="customerExploreNear" type="button" aria-pressed="false">${CUI.icon('bookings',{size:16})}<span>Near me</span></button>
      <p class="muted small" id="customerExploreNearNote" role="status"></p></div>
    <div id="customerExploreResults" role="region" aria-live="polite" aria-label="Search results">${customerExploreResultsMarkupV244({status:'loading'})}</div>`});
  const input=$('customerExploreQuery'),results=$('customerExploreResults'),
    nearButton=$('customerExploreNear'),nearNote=$('customerExploreNearNote');
  /* The customer's position is held for this render only and travels no further than the RPC
     argument — nothing stores it, and turning Near me off forgets it immediately. */
  let searchEpoch=0,debounce=0,position=null;
  const run=async(query)=>{
    const epoch=++searchEpoch;
    results.innerHTML=customerExploreResultsMarkupV244({status:'loading'});
    const {data,error}=await customerRpc('customer_explore_businesses_v244',{
      p_query:query||null,p_lat:position?.lat??null,p_lng:position?.lng??null
    });
    /* v255 (audit class E — the highest-value signal the product was losing every day). The
       SHAPE only: how many words, how long, and whether anything matched. Never the words.
       Discovery is not business-scoped, so this is the one event recorded with no tenant. */
    if(!error)typeof recordProductInteractionV100==='function'&&recordProductInteractionV100('customer.explore_searched',null,{
      context:{query_shape:exploreQueryShapeV256(query,Array.isArray(data)&&data.length>0),
        surface_key:'explore',entry_point:'customer_explore',surface_version:'v255'}
    });
    /* Replies can land out of order — a stale reply must never overwrite a newer query's list. */
    if(!isCurrent()||epoch!==searchEpoch||!results.isConnected)return;
    results.innerHTML=customerExploreResultsMarkupV244(error
      ?{status:'error'}
      :{status:'ready',rows:Array.isArray(data)?data:[],query,near:!!position});
    const retry=$('customerExploreRetry');
    if(retry)retry.onclick=()=>run(input.value.trim());
  };
  const setNear=(next,note='')=>{
    position=next;
    nearButton.setAttribute('aria-pressed',String(!!next));
    nearButton.classList.toggle('is-on',!!next);
    nearNote.textContent=note;
  };
  nearButton.onclick=()=>{
    if(position){setNear(null,'');run(input.value.trim());return}
    if(!navigator.geolocation){
      setNear(null,'This browser cannot share your location. Search by name instead.');
      return;
    }
    nearButton.disabled=true;nearNote.textContent='Finding you…';
    navigator.geolocation.getCurrentPosition(reading=>{
      nearButton.disabled=false;
      if(!isCurrent())return;
      setNear({lat:reading.coords.latitude,lng:reading.coords.longitude},'');
      run(input.value.trim());
    },error=>{
      nearButton.disabled=false;
      if(!isCurrent())return;
      /* Denial is a decision, not a failure: say what happened, keep the list the customer has. */
      setNear(null,error?.code===1
        ?'Location is off for this site. Turn it on in your browser to sort by distance.'
        :'Your location could not be read just now. The list is still here, sorted by name.');
    },{enableHighAccuracy:false,timeout:8000,maximumAge:60000});
  };
  input.addEventListener('input',()=>{
    clearTimeout(debounce);
    debounce=setTimeout(()=>run(input.value.trim()),300);
  });
  input.addEventListener('keydown',event=>{
    if(event.key==='Enter'){event.preventDefault();clearTimeout(debounce);run(input.value.trim())}
  });
  run('');
  focusCustomerRoute();
}
/* v290 (owner: "build the road from 8 to 9") — the in-app landing for a shared offer.
   The /o/ share page hands humans to #/offer/<id>. Three honest outcomes:
     * a STRANGER (signed out) is forwarded to the business's public page — the same place the
       old link went — after one anonymous read; never a sign-in wall;
     * a signed-in customer sees the offer itself — artwork uncropped, the Peekaa × firm
       pairing, validity with LIVE state (ends today / N days left / ended) — and one CTA that
       knows whether they are linked: their own rewards page when they are, the business's
       public page when they are not;
     * a dead or unknown offer says so and offers Home, because a shared link outlives the
       offer it carried. */
function customerOfferLandingStateV290(endsAt,now=new Date()){
  const ends=new Date(endsAt||'');
  if(Number.isNaN(ends.getTime()))return '';
  if(ends.getTime()<now.getTime())return 'Ended';
  /* Calendar days in SGT — every date on the customer surface is Singapore time, and an offer
     ending at 23:59 tonight "ends today", not "tomorrow" because 24 hours have not elapsed. */
  const sgDay=at=>Math.floor((at.getTime()+8*3600000)/86400000);
  const days=sgDay(ends)-sgDay(now);
  if(days<=0)return 'Ends today';
  return days===1?'Ends tomorrow':`${days} days left`;
}
async function renderCustomerOfferLandingV290(offerId){
  const id=String(offerId||'').trim().toLowerCase();
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id))return nav('#/wallet');
  if(!S.user){
    const {data}=await customerRpc('offer_share_page_v268',{p_offer:id});
    const slug=String(data?.business_slug||'').trim();
    return nav(slug?`#/b/${encodeURIComponent(slug)}`:'#/wallet');
  }
  const walletRenderEpoch=++customerWalletRenderEpoch,isCurrent=()=>customerWalletRenderEpoch===walletRenderEpoch;
  const context=await loadCustomerSurfaceContext(isCurrent);if(!context)return;
  renderCustomerShell({active:'home',backTo:'#/wallet',staffWorkspaces:context.staffWorkspaces,
    messagesAvailable:context.features.customer_in_app_inbox===true,
    body:CUI.loadingState({title:'Offer',iconName:'loyalty'})});
  const [offerResult,programmesResult]=await Promise.all([
    customerRpc('offer_share_page_v268',{p_offer:id}),
    customerRpc('customer_list_programmes_v89')
  ]);
  if(!isCurrent())return;
  const offer=offerResult.error?null:offerResult.data;
  if(!offer){
    $('walletBody').innerHTML=`<header class="customer-page-head"><div><h1>This offer has ended</h1><p class="muted">The link you followed is for an offer that is no longer running.</p></div></header>
      <section class="card"><p class="muted small">Businesses you join keep their current offers on your Home.</p><a class="btn" href="#/wallet" style="margin-top:14px">Open Home</a></section>`;
    focusCustomerRoute();return;
  }
  const slug=String(offer.business_slug||'').trim();
  const linked=(Array.isArray(programmesResult.data?.programmes)?programmesResult.data.programmes
    :Array.isArray(programmesResult.data)?programmesResult.data:[])
    .some(programme=>String(programme?.business?.slug||programme?.business_slug||'')===slug);
  const artwork=customerMediaUrlV95(offer.image_url),
    validity=customerPromotionValidityV104({starts_at:offer.starts_at,ends_at:offer.ends_at}),
    liveState=customerOfferLandingStateV290(offer.ends_at);
  $('walletBody').innerHTML=`<header class="customer-page-head"><div><p class="customer-quest-kicker">Shared offer</p><h1 data-merchant-content>${esc(offer.name||'Offer')}</h1><p class="muted">${esc(customerShareCoBrandV267({name:offer.business_name}))}</p></div></header>
    <section class="card customer-offer-landing-v290">
      ${artwork?`<div class="customer-promotion-card-media"><img src="${esc(artwork)}" alt="${esc(offer.image_alt||offer.name||'Offer')}" loading="eager" style="object-fit:contain"></div>`:''}
      ${offer.tagline?`<p data-merchant-content style="margin-top:12px">${esc(offer.tagline)}</p>`:''}
      ${offer.description&&offer.description!==offer.tagline?`<p class="muted small" data-merchant-content style="margin-top:8px">${esc(offer.description)}</p>`:''}
      <p class="muted small" style="margin-top:12px">${esc([validity,liveState].filter(Boolean).join(' · '))}</p>
      <div class="row" style="margin-top:16px">
        ${linked?`<a class="btn" href="#/wallet/${encodeURIComponent(slug)}">Open ${esc(offer.business_name||'business')} rewards</a>`
          :slug?`<a class="btn" href="#/b/${encodeURIComponent(slug)}">${esc(`View ${offer.business_name||'the business'}`)}</a>`:''}
        <a class="btn ghost sm" href="#/wallet">Home</a>
      </div>
      ${linked?'':`<p class="muted small" style="margin-top:12px">${esc(ct('qrOnlyHelp'))}</p>`}
    </section>`;
  focusCustomerRoute();
}

function renderCustomerWalletUnavailable(message='Customer wallet access is not available yet.'){
  setCustomerSurfaceDocumentV167();
  globalThis.document?.documentElement?.setAttribute('lang','en');
  root.innerHTML=`<div class="wallet-shell customer-surface"><div class="wallet-inner"><div class="wallet-head">
    <div class="logo">${brandWordmark()}</div><span class="spacer"></span><button class="btn ghost sm" id="walletSignOut">Sign out</button></div>
    <div class="card" style="text-align:center;padding:34px 22px"><h2>${esc(BRAND.customerLabel)} is not open yet</h2>
      <p class="muted" style="margin-top:8px">${esc(message)}</p>
    </div>${accountDeletionCardHtml()}${legalLinks()}</div></div>`;
  wireAccountDeletionButton();
  $('walletSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
}

function renderCustomerCapabilityRetry(message){
  setCustomerSurfaceDocumentV167();
  root.innerHTML=`<div class="wallet-shell customer-surface"><div class="wallet-inner"><div class="wallet-head">
    <div class="logo">${brandWordmark()}</div><span class="spacer"></span><button class="btn ghost sm" id="walletSignOut">Sign out</button></div>
    <div class="card" style="text-align:center;padding:34px 22px"><h2>${esc(BRAND.customerLabel)} could not load</h2>
      <p class="muted" style="margin-top:8px">${esc(message)}</p>
      <button class="btn" id="customerCapabilityRetry" style="margin-top:16px">Try again</button>
    </div>${accountDeletionCardHtml()}${legalLinks()}</div></div>`;
  wireAccountDeletionButton();
  $('customerCapabilityRetry').onclick=()=>{customerFeatureCapabilities=null;route()};
  $('walletSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
}

function walletDate(value,withTime=false){
  if(!value)return '';
  const date=new Date(value);if(Number.isNaN(date.getTime()))return '';
  return date.toLocaleString('en-SG',{timeZone:'Asia/Singapore',dateStyle:'medium',...(withTime?{timeStyle:'short'}:{})});
}

function customerPointTotalV103(value){
  return new Intl.NumberFormat('en-SG',{maximumFractionDigits:0})
    .format(Math.max(0,Number(value)||0));
}
/* v194 (owner struck the second line out as "redundant", and asked what the "Terms" toggle was
   for): a tagline that only repeats the offer name is noise, and terms hidden behind a bare word
   read as a control with no purpose. The tagline is dropped when it echoes the title — compared on
   letters and digits, so "50% off first prata" is recognised inside "National Day: 50% off first
   prata" — and the terms are shown as plain small text rather than a mystery disclosure. */
function customerOfferTaglineV194(name,tagline){
  const clean=value=>String(value||'').toLowerCase().replace(/[^a-z0-9]+/g,'');
  const title=clean(name),line=clean(tagline);
  if(!line)return '';
  if(!title)return String(tagline).trim();
  return title.includes(line)||line.includes(title)?'':String(tagline).trim();
}
/* v195 (owner struck the repeated line on the CARD too, and struck the tail of the description):
   both are copy this app generated, not copy a merchant wrote. promotionCopyAssistV104 builds the
   description as "<facts> at <business>. Available until <date>. <call to action>", and the sheet
   already prints the validity as its own row and the action as a button — so the tail says the
   same thing three times. Only OUR generated sentences are removed, matched exactly; a merchant's
   own words, including their own dates, are never touched. */
const PROMOTION_GENERATED_TAIL_V195=Object.freeze([
  /\s*Book now to enjoy this offer\.\s*$/i,
  /\s*View the offer and plan your visit\.\s*$/i,
  /\s*Show this offer at the counter when you visit\.\s*$/i,
  /\s*Available until [^.]{3,40}\.\s*$/i
]);
function customerOfferDescriptionV195(description){
  let text=String(description||'').trim();
  for(const pattern of PROMOTION_GENERATED_TAIL_V195)text=text.replace(pattern,'').trim();
  return text;
}
function customerPromotionCtaV104(item,business,bookingEnabled){
  const metadata=item?.metadata||{},cta=metadata.cta||{},
    requestedKind=String(cta.kind||metadata.cta_kind||'programme'),
    kind=requestedKind==='book'&&!bookingEnabled?'programme':requestedKind;
  const configured=String(cta.label||metadata.cta_label||'').trim();
  if(kind==='book'&&bookingEnabled){
    return `<a class="btn sm" href="#/b/${encodeURIComponent(business.slug||'')}">${esc(configured||'Book now')}</a>`;
  }
  if(kind==='counter'){
    return `<button class="btn sm" type="button" data-promotion-counter>${esc(configured||'Show at counter')}</button>`;
  }
  const label=requestedKind==='book'&&!bookingEnabled?'View details':configured||'View details';
  return `<button class="btn sm" type="button" data-promotion-details>${esc(label)}</button>`;
}
function customerPromotionValidityV104(item={}){
  const starts=promotionDateTextV104(item.starts_at),ends=promotionDateTextV104(item.ends_at);
  if(starts&&ends)return `Valid ${starts} – ${ends}`;
  if(ends)return `Valid until ${ends}`;
  return starts?`Valid from ${starts}`:'';
}
/* v267 (owner: "you can put peekaa x (company name) - with our logos together"). A share is a
   customer vouching for a business, so it goes out CO-BRANDED: the platform and the firm side by
   side, never Peekaa alone and never the firm alone.
   The line is built from the firm's own name, so it reads "Peekaa × Cubbly" — and degrades to
   plain "Peekaa" rather than "Peekaa × " when a business has somehow lost its name. */
const CUSTOMER_BRAND_NAME_V267='Peekaa',CUSTOMER_BRAND_MARK_V267='/icons/peekaa-192.png';
function customerShareCoBrandV267(business={}){
  const shop=String(business?.name||'').trim();
  return shop?`${CUSTOMER_BRAND_NAME_V267} × ${shop}`:CUSTOMER_BRAND_NAME_V267;
}
function customerShareButtonMarkupV264(offerId,{small=true}={}){
  return `<button class="btn ghost${small?' sm':''} customer-share-button" type="button" data-share-offer="${esc(offerId||'')}" aria-label="Share this offer">${CUI.icon('share',{size:16})}<span>Share</span></button>`;
}
function customerPromotionCardV104(item,business,bookingEnabled,previewImageUrl=''){
  const image=previewImageUrl||customerMediaUrlV95(item?.image_url),
    validity=customerPromotionValidityV104(item),
    facts=customerOfferTaglineV194(item?.name,String(item?.metadata?.offer_facts||'')),
    description=customerOfferDescriptionV195(item?.description),
    terms=String(item?.terms||'').trim();
  const initial=(String(item?.name||'Offer').trim()[0]||'O').toUpperCase();
  return `<article class="customer-promotion-card" data-promotion-id="${esc(item?.id||'')}">
    ${image?`<div class="customer-promotion-card-media"><img src="${esc(image)}" alt="${esc(item?.image_alt||item?.imageAlt||item?.name||'Promotion')}" loading="eager"></div>`:`<div class="customer-promotion-card-media customer-promotion-card-media--fallback" aria-hidden="true"><span>${esc(initial)}</span></div>`}
    <div class="customer-promotion-card-copy">
      <p class="customer-quest-kicker">Limited-time offer</p>
      <h3>${esc(item?.name||'Latest offer')}</h3>
      ${facts?`<p class="customer-promotion-card-facts">${esc(facts)}</p>`:''}
      ${customerOfferTaglineV194(item?.name,item?.tagline)||description?`<p>${esc(customerOfferTaglineV194(item?.name,item?.tagline)||description)}</p>`:''}
      ${validity?`<p class="customer-promotion-validity">${esc(validity)}</p>`:''}
      <div class="customer-promotion-card-actions">
        ${customerPromotionCtaV104(item,business,bookingEnabled)}
        ${customerShareButtonMarkupV264(item?.id)}
        ${terms?`<details><summary class="small">Terms</summary><p class="small" style="margin-top:6px">${esc(terms)}</p></details>`:''}
      </div>
      <p class="small" data-promotion-status role="status" aria-live="polite" style="margin-top:8px"></p>
      <template data-promotion-details-template>
        <p>${esc(description||item?.tagline||facts||item?.name||'Latest offer')}</p>
        <dl class="customer-promotion-detail-list">
          ${facts?`<div><dt>Offer</dt><dd>${esc(facts)}</dd></div>`:''}
          ${validity?`<div><dt>Validity</dt><dd>${esc(validity)}</dd></div>`:''}
          ${terms?`<div><dt>Terms</dt><dd>${esc(terms)}</dd></div>`:''}
        </dl>
        <p class="muted small">Show these details to the team when you visit.</p>
      </template>
    </div>
  </article>`;
}
async function renderCustomerNotificationPreferences(businessSlug,isCurrent=()=>true){
  const host=$('customerNotificationPreferences');if(!walletSectionStillCurrent(host,isCurrent))return;
  const {data,error}=await sb.rpc('customer_get_notification_preferences',{p_business_slug:businessSlug});
  if(!walletSectionStillCurrent(host,isCurrent))return;
  if(error)return toast('Notification settings could not be saved. Please try again.');
  const current=new Map((data||[]).map(x=>[`${x.channel}:${x.topic}`,!!x.opted_in]));
  const choices=[['in_app','booking_updates','Booking updates'],['in_app','loyalty_updates','Loyalty updates'],['email','marketing','Offers by email']];
  host.innerHTML=`<h2 style="margin-top:28px">Notifications</h2>${choices.map(([channel,topic,label])=>`<label class="row" style="margin-top:10px;color:var(--ink);font-weight:500">
    <input class="walletPref" type="checkbox" style="width:auto" data-channel="${channel}" data-topic="${topic}" ${current.get(`${channel}:${topic}`)?'checked':''}>${label}</label>`).join('')}`;
  document.querySelectorAll('.walletPref').forEach(input=>input.onchange=async()=>{
    input.disabled=true;
    const {error:setError}=await sb.rpc('customer_set_notification_preference',{
      p_business_slug:businessSlug,p_channel:input.dataset.channel,p_topic:input.dataset.topic,
      p_opted_in:input.checked,p_idempotency_key:crypto.randomUUID()});
    if(!walletSectionStillCurrent(host,isCurrent)||!input.isConnected)return;
    input.disabled=false;
    if(setError){input.checked=!input.checked;return toast('Notification settings could not be saved. Please try again.')}
    toast('Notification preference saved');
  });
}

async function returnToNativeSignIn(){
  if(S.user){killChannels();await sb.auth.signOut();resetClientSessionState()}
  renderAuth('in');
}

function renderNativeBusinessCompanion(){
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="nativeBusinessTitle">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    <h1 id="nativeBusinessTitle" style="font-size:1.55rem;margin:14px 0 6px">Peekaa for existing business accounts</h1>
    <p class="muted" style="line-height:1.6">This app is a purchase-free companion for businesses with an existing Peekaa subscription.</p>
    <p class="muted small" style="line-height:1.6;margin-top:8px">New business accounts, subscription setup, and subscription changes are not available in this app.</p>
    <button class="btn" id="nativeBusinessSignIn" style="width:100%;margin-top:18px">${S.user?'Sign out and return to sign in':'Back to sign in'}</button>
    ${S.user?accountDeletionCardHtml():''}${legalLinks()}</section></main>`;
  $('main')?.focus();
  $('nativeBusinessSignIn').onclick=returnToNativeSignIn;
  wireAccountDeletionButton();
}

function businessApplicationInviteToken(){
  const token=new URLSearchParams(location.search).get('invite')||'';
  return /^[0-9a-f]{64}$/i.test(token)?token.toLowerCase():'';
}
const STAFF_INVITE_STORAGE_V151='peekaa:pending-staff-invite:v151';
function normalizeCompanyInviteCodeV151(value){
  const code=String(value||'').replace(/[\s-]+/g,'').trim().toUpperCase();
  return /^[A-Z0-9]{4,32}$/.test(code)?code:'';
}
function businessStaffInviteCodeV151(){
  const params=new URLSearchParams(location.search||'');
  const hashParams=new URLSearchParams(String(location.hash||'').split('?')[1]||'');
  const query=params.get('staff_invite')||params.get('company_invite')||params.get('invite_code')||'';
  const hash=query||hashParams.get('staff_invite')||hashParams.get('company_invite')||hashParams.get('invite_code')||'';
  return normalizeCompanyInviteCodeV151(hash)||normalizeCompanyInviteCodeV151(sessionStorage.getItem(STAFF_INVITE_STORAGE_V151));
}
function rememberBusinessStaffInviteV151(code){
  const normalized=normalizeCompanyInviteCodeV151(code);
  if(normalized)sessionStorage.setItem(STAFF_INVITE_STORAGE_V151,normalized);
  return normalized;
}
function staffInviteOAuthRedirectV158(code){
  const url=new URL(NestlyNativeBridge.publicUrl('/business'));
  url.searchParams.set('staff_invite',normalizeCompanyInviteCodeV151(code)||String(code||'').trim());
  return url.toString();
}
function staffInvitePreviewMarkupV151(preview){
  if(!preview)return '<p class="muted small">Enter a company invite code to check the business and role.</p>';
  const role=ROLE_LABELS[preview.role]||preview.role||'Team member';
  if(preview.status==='valid'){
    return `<div class="ok" style="margin-top:10px;background:#E7F6EE;color:var(--green)">
      <b>${esc(preview.business_name||'Business found')}</b>
      <p class="small" style="margin-top:5px">Role offered: ${esc(role)}</p>
      <p class="small" style="margin-top:5px">${preview.restricted_email?`Restricted to: ${esc(preview.restricted_email)}`:'No email restriction on this invite.'}</p>
    </div>`;
  }
  const messages={
    invalid:'This company invite code is invalid.',
    expired:'This company invite has expired.',
    revoked:'This company invite has been revoked.',
    already_used:'This company invite has already been used.',
    business_unavailable:'The business for this invite is unavailable.'
  };
  return `<div class="err">${esc(messages[preview.status]||'This company invite cannot be used.')}</div>`;
}
async function previewStaffInviteV151(code,targetId){
  const target=$(targetId);
  const normalized=rememberBusinessStaffInviteV151(code);
  if(!target)return null;
  if(!normalized){target.innerHTML=staffInvitePreviewMarkupV151(null);return null}
  target.innerHTML='<p class="muted small">Checking company invite…</p>';
  const {data,error}=await sb.rpc('preview_staff_invite',{p_code:normalized});
  const preview=error?{status:'invalid'}:data;
  target.innerHTML=staffInvitePreviewMarkupV151(preview);
  return preview;
}
function renderBusinessSignupChoice(){
  destroyMountedTurnstiles();
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="card entry-choice-card auth-card" aria-labelledby="businessSignupChoiceTitle">
    <div class="logo">${brandWordmark()}</div>
    <h1 id="businessSignupChoiceTitle" style="font-size:clamp(1.8rem,6vw,2.45rem);margin-top:18px">How would you like to use Peekaa?</h1>
    <p class="muted" style="margin-top:7px;line-height:1.55">Choose the path that matches what you are doing now.</p>
    <div class="entry-choice-grid">
      <button type="button" class="entry-choice" id="requestDemoChoice"><span class="entry-choice-icon">${CUI.icon('info',{size:25})}</span><div><h2>Request a demo</h2><p class="muted">Ask Peekaa consultants to contact you. No account or workspace is created.</p></div><span class="inline-status" style="font-weight:700;color:var(--coral)">Request demo ${CUI.icon('forward',{size:17})}</span></button>
      <button type="button" class="entry-choice" id="startBusinessChoice"><span class="entry-choice-icon">${CUI.icon('branch',{size:25})}</span><div><h2>Set up business</h2><p class="muted">Create a new Peekaa workspace, then choose Stripe Checkout or manual payment approval.</p></div><span class="inline-status" style="font-weight:700;color:var(--coral)">Continue ${CUI.icon('forward',{size:17})}</span></button>
      <button type="button" class="entry-choice" id="joinBusinessChoice"><span class="entry-choice-icon">${CUI.icon('staff',{size:25})}</span><div><h2>Join an existing business</h2><p class="muted">Use an invitation from your business owner or manager.</p></div><span class="inline-status" style="font-weight:700;color:var(--coral)">Enter invite ${CUI.icon('forward',{size:17})}</span></button>
    </div>
    <button class="btn ghost" id="businessSignupBack" style="width:100%;margin-top:18px">Back to sign in</button>
    ${legalLinks()}</section></main>`;
  CUI.focusRoute($('main'),{enhanceContent:true});
  $('requestDemoChoice').onclick=()=>renderBusinessDemoRequest();
  $('startBusinessChoice').onclick=()=>{return renderBusinessApplication()};
  $('joinBusinessChoice').onclick=()=>renderStaffInviteAuthV151('in',businessStaffInviteCodeV151());
  $('businessSignupBack').onclick=()=>renderAuth('in');
}
function renderBusinessDemoRequest(){
  destroyMountedTurnstiles();
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="businessDemoRequestTitle">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    <h1 id="businessDemoRequestTitle" style="margin:14px 0 2px">Request a Peekaa demo</h1>
    <p class="muted small" style="margin-top:6px">Demo request only. Peekaa consultants will contact you. No owner account, workspace, login, Stripe Checkout, or Super Admin approval is created from this demo request.</p>
    <div class="grid2" style="margin-top:14px">
      <div><label for="demoContactName">Your full name</label><input id="demoContactName" autocomplete="name"></div>
      <div><label for="demoBusinessName">Business name</label><input id="demoBusinessName" autocomplete="organization"></div>
      <div><label for="demoContactEmail">Email</label><input id="demoContactEmail" type="email" autocomplete="email" placeholder="you@business.com"></div>
      <div><label for="demoContactPhone">Singapore mobile</label><input id="demoContactPhone" autocomplete="tel" inputmode="tel" placeholder="+65 8123 4567"></div>
      <div><label for="demoBusinessSector">Business sector (optional)</label><input id="demoBusinessSector" autocomplete="off" placeholder="e.g. F&B, salon, spa"></div>
      <div class="wide"><label for="demoNotes">What would you like to see? (optional)</label><textarea id="demoNotes" rows="3" placeholder="Tell us what you want to test or ask."></textarea></div>
    </div>
    <div id="businessDemoRequestError" role="alert"></div>
    <button class="btn" id="businessDemoRequestSubmit" style="width:100%;margin-top:18px">Send demo request</button>
    <button class="btn ghost" id="businessDemoRequestBack" style="width:100%;margin-top:10px">Back</button>
    <p class="muted small" id="businessDemoRequestStatus" role="status" aria-live="polite" style="margin-top:8px">This opens your email app with the demo details. It does not create a Peekaa login.</p>
    ${legalLinks()}</section></main>`;
  CUI.focusRoute($('main'),{enhanceContent:true});
  $('businessDemoRequestBack').onclick=()=>renderBusinessSignupChoice();
  $('businessDemoRequestSubmit').onclick=()=>{
    const name=String($('demoContactName')?.value||'').trim();
    const business=String($('demoBusinessName')?.value||'').trim();
    const email=String($('demoContactEmail')?.value||'').trim();
    const phone=String($('demoContactPhone')?.value||'').trim();
    const sector=String($('demoBusinessSector')?.value||'').trim();
    const notes=String($('demoNotes')?.value||'').trim();
    if(!name||!business||!email||!phone){
      $('businessDemoRequestError').innerHTML='<div class="err">Enter your name, business name, email and mobile number so Peekaa can contact you.</div>';
      return;
    }
    $('businessDemoRequestError').innerHTML='';
    const subject='Peekaa demo request';
    const body=[
      'Please contact me for a Peekaa demo.',
      '',
      `Name: ${name}`,
      `Business: ${business}`,
      `Email: ${email}`,
      `Mobile: ${phone}`,
      `Sector: ${sector||'-'}`,
      '',
      `Notes: ${notes||'-'}`,
      '',
      'I understand this is a demo request only. No Peekaa account, workspace, login, Stripe Checkout, or Super Admin approval is created from this request.'
    ].join('\n');
    $('businessDemoRequestStatus').textContent='Opening your email app…';
    window.location.href=`mailto:admin.peekaa@gmail.com?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
  };
}
function renderStaffInviteAuthV151(mode='in',initialCode=''){
  destroyMountedTurnstiles();
  const saved=rememberBusinessStaffInviteV151(initialCode)||businessStaffInviteCodeV151();
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="staffInviteAuthTitle">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    <h1 id="staffInviteAuthTitle" style="margin:14px 0 2px">Join an existing business</h1>
    <p class="muted small" style="margin-top:6px">Enter your company invite code, then sign in or create a staff account. Stripe is not required for invited staff.</p>
    <label for="staffInviteCodeV151">Company invite code</label><input id="staffInviteCodeV151" autocomplete="one-time-code" autocapitalize="characters" spellcheck="false" placeholder="e.g. 7FE22596" value="${esc(saved)}">
    <div id="staffInvitePreviewV151" role="status" aria-live="polite" style="margin-top:8px">${staffInvitePreviewMarkupV151(null)}</div>
    <div class="row" style="gap:8px;margin-top:14px"><button type="button" class="btn ${mode==='in'?'':'ghost'} sm" id="staffInviteSignInTab">Sign in</button><button type="button" class="btn ${mode==='up'?'':'ghost'} sm" id="staffInviteSignUpTab">Create account</button></div>
    <label for="staffInviteEmailV151">Email</label><input id="staffInviteEmailV151" type="email" autocomplete="email" placeholder="you@business.com">
    <label for="staffInvitePasswordV151">Password</label>${passwordControlHtml('staffInvitePasswordV151',{autocomplete:mode==='in'?'current-password':'new-password',placeholder:'••••••••'})}
    ${mode==='up'?`<label for="staffInvitePasswordConfirmV151">Confirm password</label>${passwordControlHtml('staffInvitePasswordConfirmV151',{autocomplete:'new-password',placeholder:'••••••••'})}`:''}
    <div id="staffInviteAuthError"></div>
    ${businessGoogleButtonHtml('staffInviteGoogleV158')}
    <p class="muted small" style="margin-top:8px">Google works for invited staff too. Peekaa still validates the company invite and role on the server before access is created.</p>
    ${authChallengeHtml()}
    <button class="btn" id="staffInviteAuthGo" style="width:100%;margin-top:18px" disabled>${mode==='in'?'Sign in and continue':'Create account and continue'}</button>
    <button class="btn ghost" id="staffInviteBack" style="width:100%;margin-top:10px">Back</button>
    ${legalLinks()}</section></main>`;
  bindPasswordVisibility(root);
  CUI.focusRoute($('main'),{enhanceContent:true});
  $('staffInviteSignInTab').onclick=()=>renderStaffInviteAuthV151('in',$('staffInviteCodeV151').value);
  $('staffInviteSignUpTab').onclick=()=>renderStaffInviteAuthV151('up',$('staffInviteCodeV151').value);
  $('staffInviteBack').onclick=()=>renderBusinessSignupChoice();
  $('staffInviteGoogleV158').onclick=async()=>{
    const code=rememberBusinessStaffInviteV151($('staffInviteCodeV151').value);
    if(!code){$('staffInviteAuthError').innerHTML='<div class="err">Enter a valid company invite code before continuing with Google.</div>';return}
    const preview=await previewStaffInviteV151(code,'staffInvitePreviewV151');
    if(preview?.status&&preview.status!=='valid'){$('staffInviteAuthError').innerHTML='<div class="err">Use a valid active company invite before continuing with Google.</div>';return}
    $('staffInviteGoogleV158').disabled=true;
    try{
      const {error}=await sb.auth.signInWithOAuth({
        provider:'google',
        options:{redirectTo:staffInviteOAuthRedirectV158(code),queryParams:{prompt:'select_account'}}
      });
      if(error)throw error;
    }catch(error){
      $('staffInviteAuthError').innerHTML=`<div class="err">${esc(error.message||'Google sign-in could not be started.')}</div>`;
      $('staffInviteGoogleV158').disabled=false;
    }
  };
  if(saved)previewStaffInviteV151(saved,'staffInvitePreviewV151');
  $('staffInviteCodeV151').addEventListener('blur',()=>previewStaffInviteV151($('staffInviteCodeV151').value,'staffInvitePreviewV151'));
  let authToken='',authControl=null;
  mountTurnstile(AUTH_TURNSTILE_SITE_KEY,{container:'authTurnstile',status:'authTurnstileStatus',
    retry:'authTurnstileRetry',action:'frenly_staff_invite',
    onToken:(token)=>{authToken=token;$('staffInviteAuthGo').disabled=!token}})
    .then(control=>authControl=control);
  $('staffInviteAuthGo').onclick=async()=>{
    const code=rememberBusinessStaffInviteV151($('staffInviteCodeV151').value);
    const email=$('staffInviteEmailV151').value.trim();
    const password=$('staffInvitePasswordV151').value;
    if(!code){$('staffInviteAuthError').innerHTML='<div class="err">Enter a valid company invite code.</div>';return}
    const preview=await previewStaffInviteV151(code,'staffInvitePreviewV151');
    if(preview?.status&&preview.status!=='valid'){$('staffInviteAuthError').innerHTML='<div class="err">Use a valid active company invite before continuing.</div>';return}
    if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)){$('staffInviteAuthError').innerHTML='<div class="err">Enter the email you want to use for this workspace.</div>';return}
    if(mode==='up'&&(!validNewPassword(password)||password!==$('staffInvitePasswordConfirmV151').value)){
      $('staffInviteAuthError').innerHTML='<div class="err">Use 12+ characters with upper/lowercase, a number and symbol; both passwords must match.</div>';return;
    }
    if(!authToken)return;
    $('staffInviteAuthGo').disabled=true;
    const captchaToken=authToken;authToken='';
    try{
      if(mode==='up'){
        const returnUrl=new URL(NestlyNativeBridge.publicUrl('/business'));returnUrl.searchParams.set('staff_invite',code);
        const {data,error}=await sb.auth.signUp({email,password,options:{captchaToken,emailRedirectTo:returnUrl.toString(),data:{account_type:'business_staff_invite'}}});
        if(error)throw error;
        if(!data.session){
          if(authControl)authControl.reset();
          $('staffInviteAuthError').innerHTML='<div class="err" style="background:#E7F6EE;color:var(--green)">Check your email to confirm your account, then return to this invite link.</div>';return;
        }
      }else{
        const {error}=await sb.auth.signInWithPassword({email,password,options:{captchaToken}});
        if(error)throw error;
      }
      history.replaceState(null,'',`/business?staff_invite=${encodeURIComponent(code)}`);
      resetClientSessionState({preserveInvitation:true});route();
    }catch(error){
      if(authControl)authControl.reset();
      $('staffInviteAuthError').innerHTML=`<div class="err">${esc(error.message||'Invite sign-in could not be completed.')}</div>`;
      $('staffInviteAuthGo').disabled=false;
    }
  };
}
function businessApplicationCopy(locale,key){
  const copy={
    en:{
      apply:'Apply for a Peekaa business account',applyIntro:'Tell us about your business. A Peekaa super admin must approve it before an owner account can be created.',
      contactName:'Your full name',contactEmail:'Business email',contactPhone:'Singapore mobile number',businessName:'Business name',
      sector:'Business sector',registration:'UEN / registration number (optional)',language:'Preferred language',
      consent:'I have read and agree to the Terms and Privacy Policy.',submit:'Submit for approval',
      submitted:'Application received',reference:'Save this reference',await:'Peekaa will review your application. No owner account exists yet.',
      approved:'Create your approved owner account',approvedIntro:'This invitation is bound to the approved email and can be used only once.',
      password:'Password',confirm:'Confirm password',create:'Create owner account',signIn:'Back to sign in',
      terms:'Terms',privacy:'Privacy',acceptLegal:'Please accept the Terms and Privacy Policy.',
      genericError:'We could not complete this request. Please check the details and try again.',
      passwordRule:'Use 12+ characters with upper/lowercase, a number and symbol; both passwords must match.',
      checkEmail:'Check the approved email, confirm the account, then return through the same secure invitation.',
      invitationUnavailable:'Invitation unavailable',invitationUnavailableIntro:'This approved invitation is invalid, expired, or already used.',
      signOut:'Sign out',createWorkspace:'Create workspace',finalStep:'Final step: choose the workspace address. The approved invitation and signed-in email will be checked again.',
      workspaceAddress:'Workspace address',createApprovedWorkspace:'Create approved workspace',
      workspaceCreateError:'This workspace could not be created.'
    },
    'zh-CN':{
      apply:'申请 Peekaa 商家账户',applyIntro:'请填写商家资料。超级管理员批准后，才能创建店主账户。',
      contactName:'您的姓名',contactEmail:'商家邮箱',contactPhone:'新加坡手机号码',businessName:'商家名称',
      sector:'行业',registration:'UEN／注册号码（选填）',language:'首选语言',
      consent:'我已阅读并同意条款及隐私政策。',submit:'提交审核',
      submitted:'申请已收到',reference:'请保存此申请编号',await:'Peekaa 将审核您的申请。目前尚未创建店主账户。',
      approved:'创建已批准的店主账户',approvedIntro:'此邀请仅限已批准的邮箱使用，并且只能使用一次。',
      password:'密码',confirm:'确认密码',create:'创建店主账户',signIn:'返回登录',
      terms:'条款',privacy:'隐私政策',acceptLegal:'请接受条款和隐私政策。',
      genericError:'无法完成此请求。请检查资料后重试。',
      passwordRule:'请使用至少 12 个字符，并包含大小写字母、数字和符号；两次密码必须一致。',
      checkEmail:'请查看已批准的邮箱并确认账户，然后通过同一个安全邀请返回。',
      invitationUnavailable:'邀请不可用',invitationUnavailableIntro:'此批准邀请无效、已过期或已使用。',
      signOut:'退出登录',createWorkspace:'创建工作区',finalStep:'最后一步：选择工作区地址。系统将再次核对已批准的邀请和当前登录邮箱。',
      workspaceAddress:'工作区地址',createApprovedWorkspace:'创建已批准的工作区',
      workspaceCreateError:'无法创建此工作区。'
    },
    ms:{
      apply:'Mohon akaun perniagaan Peekaa',applyIntro:'Beritahu kami tentang perniagaan anda. Pentadbir Peekaa perlu meluluskannya sebelum akaun pemilik boleh dicipta.',
      contactName:'Nama penuh anda',contactEmail:'E-mel perniagaan',contactPhone:'Nombor telefon Singapura',businessName:'Nama perniagaan',
      sector:'Sektor perniagaan',registration:'UEN / nombor pendaftaran (pilihan)',language:'Bahasa pilihan',
      consent:'Saya telah membaca dan bersetuju dengan Terma dan Dasar Privasi.',submit:'Hantar untuk kelulusan',
      submitted:'Permohonan diterima',reference:'Simpan rujukan ini',await:'Peekaa akan menyemak permohonan anda. Akaun pemilik belum dicipta.',
      approved:'Cipta akaun pemilik yang diluluskan',approvedIntro:'Jemputan ini terikat kepada e-mel yang diluluskan dan hanya boleh digunakan sekali.',
      password:'Kata laluan',confirm:'Sahkan kata laluan',create:'Cipta akaun pemilik',signIn:'Kembali ke log masuk',
      terms:'Terma',privacy:'Privasi',acceptLegal:'Sila terima Terma dan Dasar Privasi.',
      genericError:'Permintaan ini tidak dapat diselesaikan. Semak butiran dan cuba lagi.',
      passwordRule:'Gunakan sekurang-kurangnya 12 aksara dengan huruf besar/kecil, nombor dan simbol; kedua-dua kata laluan mesti sepadan.',
      checkEmail:'Semak e-mel yang diluluskan, sahkan akaun, kemudian kembali melalui jemputan selamat yang sama.',
      invitationUnavailable:'Jemputan tidak tersedia',invitationUnavailableIntro:'Jemputan yang diluluskan ini tidak sah, telah tamat tempoh atau sudah digunakan.',
      signOut:'Log keluar',createWorkspace:'Cipta ruang kerja',finalStep:'Langkah terakhir: pilih alamat ruang kerja. Jemputan yang diluluskan dan e-mel yang sedang digunakan akan disemak sekali lagi.',
      workspaceAddress:'Alamat ruang kerja',createApprovedWorkspace:'Cipta ruang kerja yang diluluskan',
      workspaceCreateError:'Ruang kerja ini tidak dapat dicipta.'
    }
  };
  return copy[locale]?.[key]||copy.en[key]||key;
}
function businessApplicationSectorLabel(locale,key,fallback){
  const labels={
    'zh-CN':{fnb:'餐饮／咖啡馆',salon:'美发沙龙',facial:'美容／水疗',massage:'按摩',fitness:'健身',retail:'零售',other:'其他'},
    ms:{fnb:'Makanan & minuman / Kafe',salon:'Salun rambut',facial:'Rawatan muka / Spa',massage:'Urut',fitness:'Kecergasan',retail:'Runcit',other:'Lain-lain'}
  };
  return labels[locale]?.[key]||fallback;
}
function businessApplicationLanguage(){
  const locale=sessionStorage.getItem('nestly-business-application-locale');
  return WORKSPACE_LOCALES_V97.includes(locale)?locale:'en';
}
function businessOAuthRedirectUrl(){
  const redirect=new URL(NestlyNativeBridge.publicUrl('/business'));
  redirect.searchParams.set('oauth','business');
  return redirect.toString();
}
function createBusinessOAuthAdmissionClient(){
  /* OAuth provider tokens are untrusted for business access until the V138
     server admission succeeds. Keep this session memory-only so a tab close,
     crash, reload or second tab cannot observe an unadmitted Google identity. */
  return window.supabase.createClient(SB_URL,SB_KEY,{auth:{
    storageKey:'nestly-business-oauth-admission-v138',persistSession:false,
    autoRefreshToken:false,detectSessionInUrl:false,flowType:'implicit'
  }});
}
const BUSINESS_LEGAL_V138=Object.freeze({
  terms:Object.freeze({version:'2026-08-04',sha256:'012e09a4a7b6df2a5acc9da3b6512c1cfeb42e903fd8306f6ff09866a9f1e4a5'}),
  privacy:Object.freeze({version:'2026-08-10',sha256:'960434af7919e5401b3587111eb746fbba41f739edacd74cb5aeeca0402c224f'})
});
function businessGoogleButtonHtml(id){
  return `<button class="btn ghost" id="${esc(id)}" type="button" style="width:100%;min-height:44px;margin-top:12px"><span aria-hidden="true" style="font-weight:800;font-size:18px">G</span><span>Continue with Google</span></button>`;
}
function ensureCanonicalBusinessOAuthOrigin(){
  const canonical=new URL(NestlyNativeBridge.publicUrl('/business'));
  if(location.origin===canonical.origin)return true;
  location.replace(canonical.toString());
  return false;
}
async function beginBusinessGoogleOAuthAttempt({intent='signin',legalAccepted=false}={}){
  if(!['signin','signup'].includes(intent))return false;
  if(intent==='signup'&&legalAccepted!==true)return false;
  let attemptToken=null,idempotencyKey=null;
  if(intent==='signup'){
    attemptToken=crypto.randomUUID();idempotencyKey=crypto.randomUUID();
    const {data,error}=await sb.rpc('begin_business_google_oauth_signup_v138',{
      p_attempt_token:attemptToken,p_idempotency_key:idempotencyKey,
      p_terms_version:BUSINESS_LEGAL_V138.terms.version,
      p_terms_sha256:BUSINESS_LEGAL_V138.terms.sha256,
      p_privacy_version:BUSINESS_LEGAL_V138.privacy.version,
      p_privacy_sha256:BUSINESS_LEGAL_V138.privacy.sha256,p_accepted:true
    });
    if(error||data?.accepted!==true)return false;
  }
  try{
    sessionStorage.setItem('nestly-business-google-oauth',JSON.stringify({
      startedAt:Date.now(),returnPath:'/business',intent,legalAccepted:intent==='signup',
      attemptToken
    }));
    return true;
  }catch{return false}
}
function takeBusinessGoogleOAuthAttempt(){
  const key='nestly-business-google-oauth',raw=sessionStorage.getItem(key);
  sessionStorage.removeItem(key);
  if(!raw)return false;
  try{
    const attempt=JSON.parse(raw),age=Date.now()-Number(attempt?.startedAt);
    const validIntent=attempt?.intent==='signin'||(attempt?.intent==='signup'&&attempt?.legalAccepted===true);
    const validToken=attempt?.intent==='signin'||(
      typeof attempt?.attemptToken==='string'
      &&/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(attempt.attemptToken)
    );
    return attempt?.returnPath==='/business'&&validIntent&&validToken
      &&Number.isFinite(age)&&age>=0&&age<=30*60*1000
      ?{intent:attempt.intent,legalAccepted:attempt.legalAccepted===true,
        attemptToken:attempt.attemptToken||null}:false;
  }catch{return false}
}
async function startBusinessGoogleAuth({button,errorHostId,intent='signin',legalAccepted=false}){
  if(!ensureCanonicalBusinessOAuthOrigin())return;
  const errorHost=$(errorHostId);
  if(button)button.disabled=true;
  if(errorHost)errorHost.innerHTML='';
  if(await beginBusinessGoogleOAuthAttempt({intent,legalAccepted})){
    try{
      const {error}=await sb.auth.signInWithOAuth({
        provider:'google',
        options:{redirectTo:businessOAuthRedirectUrl(),scopes:'openid email profile',queryParams:{prompt:'select_account'}}
      });
      if(!error)return;
    }catch{}
  }
  sessionStorage.removeItem('nestly-business-google-oauth');
  if(button)button.disabled=false;
  if(errorHost)errorHost.innerHTML='<div class="err">Google sign-in could not be started. Try again or use email and password.</div>';
}
function renderBusinessApplication(){
  destroyMountedTurnstiles();
  let locale=businessApplicationLanguage();
  globalThis.document?.documentElement?.setAttribute('lang',locale);
  const accountCopy={
    en:{heading:'Create your Peekaa owner account',intro:'Create a secure owner login. After email confirmation, enter business details and choose Stripe Checkout or manual payment approval. Stripe opens access only after verified payment; manual payment waits for Super Admin approve/reject.',email:'Business email',password:'Password',confirm:'Confirm password',consent:'I agree to the Terms of Service and acknowledge the Privacy Policy',consentLead:'I agree to the',terms:'Terms of Service',and:'and acknowledge the',privacy:'Privacy Policy',create:'Create owner account',back:'Back',accept:'Please agree to the Terms of Service and acknowledge the Privacy Policy.',passwordRule:'Use 12+ characters with upper/lowercase, a number and symbol; both passwords must match.',error:'We could not create this account. Check the email and password, then try again.',check:'Check your email and confirm your account. Then sign in to continue business setup. Stripe payment auto-activates after verified payment; manual payment goes to Super Admin for approve/reject.'},
    'zh-CN':{heading:'创建 Peekaa 店主账户',intro:'请先创建安全登录。登录后，如方案已配置，Peekaa 会打开 Stripe Checkout；如 Stripe 暂不可用，则收集商家资料以便人工付款协助。',email:'商家邮箱',password:'密码',confirm:'确认密码',consent:'我同意服务条款，并知悉隐私政策',consentLead:'我同意',terms:'服务条款',and:'并知悉',privacy:'隐私政策',create:'创建店主账户',back:'返回登录',accept:'请同意服务条款并确认知悉隐私政策。',passwordRule:'请使用至少 12 个字符，并包含大小写字母、数字和符号；两次密码必须一致。',error:'无法创建此账户。请检查邮箱和密码后重试。',check:'请查看邮箱并确认账户，然后登录继续商家设置。如 Stripe 暂不可用，请提交资料以便人工付款协助。'},
    ms:{heading:'Cipta akaun pemilik Peekaa',intro:'Cipta log masuk selamat dahulu. Selepas log masuk, Peekaa akan membuka Stripe Checkout apabila pelan telah dikonfigurasi, atau mengumpul butiran perniagaan untuk bantuan bayaran manual.',email:'E-mel perniagaan',password:'Kata laluan',confirm:'Sahkan kata laluan',consent:'Saya bersetuju dengan Terma Perkhidmatan dan mengakui Dasar Privasi',consentLead:'Saya bersetuju dengan',terms:'Terma Perkhidmatan',and:'dan mengakui',privacy:'Dasar Privasi',create:'Cipta akaun pemilik',back:'Kembali ke log masuk',accept:'Sila bersetuju dengan Terma Perkhidmatan dan akui Dasar Privasi.',passwordRule:'Gunakan sekurang-kurangnya 12 aksara dengan huruf besar/kecil, nombor dan simbol; kedua-dua kata laluan mesti sepadan.',error:'Akaun ini tidak dapat dicipta. Semak e-mel dan kata laluan, kemudian cuba lagi.',check:'Semak e-mel dan sahkan akaun, kemudian log masuk untuk meneruskan tetapan perniagaan. Jika Stripe tidak tersedia, hantar butiran untuk bantuan bayaran manual.'}
  };
  const a=accountCopy[locale]||accountCopy.en;
  root.innerHTML=`<div class="center-wrap"><div class="auth-card card">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    <div class="row"><h2 style="margin:14px 0 2px">${esc(a.heading)}</h2><span class="spacer"></span>
      <select id="businessApplicationLocale" aria-label="Preferred language" style="width:auto"><option value="en"${locale==='en'?' selected':''}>English</option><option value="zh-CN"${locale==='zh-CN'?' selected':''}>中文</option><option value="ms"${locale==='ms'?' selected':''}>Bahasa Melayu</option></select></div>
    <p class="muted small" style="margin-top:6px">${esc(a.intro)}</p>
    <label class="checkrow" for="applicationConsent" style="margin-top:16px"><input id="applicationConsent" type="checkbox" aria-label="${esc(a.consent)}"><span>${esc(a.consentLead)} <a class="consent-document-link" href="/terms.html?return=business-signup" target="_blank" rel="noopener">${esc(a.terms)}</a> ${esc(a.and)} <a class="consent-document-link" href="/privacy.html?return=business-signup" target="_blank" rel="noopener">${esc(a.privacy)}</a>.</span></label>
    ${businessGoogleButtonHtml('businessApplicationGoogle')}
    <div class="row" aria-hidden="true" style="gap:10px;margin:16px 0 4px"><hr style="flex:1;border:0;border-top:1px solid var(--line)"><span class="muted small">or use email</span><hr style="flex:1;border:0;border-top:1px solid var(--line)"></div>
    <label for="applicationContactEmail">${esc(a.email)}</label><input id="applicationContactEmail" type="email" autocomplete="email" placeholder="you@business.com">
    <label for="businessOwnerPassword">${esc(a.password)}</label>${passwordControlHtml('businessOwnerPassword',{autocomplete:'new-password',locale})}
    <label for="businessOwnerPasswordConfirm">${esc(a.confirm)}</label>${passwordControlHtml('businessOwnerPasswordConfirm',{autocomplete:'new-password',locale})}
    <div id="businessApplicationError"></div>
    ${authChallengeHtml(locale)}
    <button class="btn" id="businessApplicationSubmit" style="width:100%;margin-top:18px" disabled>${esc(a.create)}</button>
    <button class="btn ghost" id="businessApplicationBack" style="width:100%;margin-top:10px">${esc(a.back)}</button>
    ${legalLinks(locale)}</div></div>`;
  bindPasswordVisibility(root);
  $('businessApplicationLocale').onchange=event=>{
    sessionStorage.setItem('nestly-business-application-locale',event.target.value);
    renderBusinessApplication();
  };
  $('businessApplicationBack').onclick=()=>renderBusinessSignupChoice();
  $('businessApplicationGoogle').onclick=event=>{
    if(!$('applicationConsent').checked){
      $('businessApplicationError').innerHTML=`<div class="err">${esc(a.accept)}</div>`;
      $('applicationConsent').focus();
      return;
    }
    startBusinessGoogleAuth({button:event.currentTarget,errorHostId:'businessApplicationError',intent:'signup',legalAccepted:true});
  };
  let token='',control=null;
  mountTurnstile(AUTH_TURNSTILE_SITE_KEY,{container:'authTurnstile',status:'authTurnstileStatus',
    retry:'authTurnstileRetry',action:'frenly_auth',locale,
    onToken:value=>{token=value;$('businessApplicationSubmit').disabled=!value}})
    .then(value=>control=value);
  $('businessApplicationSubmit').onclick=async()=>{
    const email=$('applicationContactEmail').value.trim().toLowerCase();
    const password=$('businessOwnerPassword').value;
    if(!$('applicationConsent').checked){
      $('businessApplicationError').innerHTML=`<div class="err">${esc(a.accept)}</div>`;return;
    }
    if(!validNewPassword(password)||password!==$('businessOwnerPasswordConfirm').value){
      $('businessApplicationError').innerHTML=`<div class="err">${esc(a.passwordRule)}</div>`;return;
    }
    $('businessApplicationSubmit').disabled=true;
    /* V286: the confirmation link used to carry ?selfserve=1 and nothing anywhere read it.
       A parameter that means nothing is worse than no parameter: it reads as a routing contract
       that does not exist. /business already resolves the right screen from the session. */
    const returnUrl=new URL(NestlyNativeBridge.publicUrl('/business'));
    const {data,error}=await sb.auth.signUp({
      email,password,options:{captchaToken:token,emailRedirectTo:returnUrl.toString(),
        data:{account_type:'business_owner',preferred_locale:locale}}
    });
    token='';
    if(error){
      if(control)control.reset();
      $('businessApplicationError').innerHTML=`<div class="err">${esc(a.error)}</div>`;
      $('businessApplicationSubmit').disabled=false;return;
    }
    if(data.session){history.replaceState(null,'','/business');route();return}
    $('businessApplicationError').innerHTML=`<div class="err" style="background:#E7F6EE;color:var(--green)">${esc(a.check)}</div>`;
  };
}
async function renderApprovedBusinessInviteSignup(inviteToken){
  destroyMountedTurnstiles();
  let invitation;
  try{invitation=await publicGateway('public-business-application',{method:'GET',query:`?invite=${encodeURIComponent(inviteToken)}`})}
  catch{return renderAuth('in')}
  const locale=WORKSPACE_LOCALES_V97.includes(invitation.preferred_locale)?invitation.preferred_locale:'en',t=key=>businessApplicationCopy(locale,key);
  globalThis.document?.documentElement?.setAttribute('lang',locale);
  root.innerHTML=`<div class="center-wrap"><div class="auth-card card"><div class="logo">${brandWordmark()}</div>
    <h2 style="margin-top:18px">${esc(t('approved'))}</h2><p class="muted small" style="margin-top:6px">${esc(t('approvedIntro'))}</p>
    <label>${esc(t('businessName'))}</label><input value="${esc(invitation.business_name||'')}" disabled>
    <label>${esc(t('contactEmail'))}</label><input id="approvedOwnerEmail" type="email" value="${esc(invitation.approved_email||'')}" readonly>
    <label for="approvedOwnerPassword">${esc(t('password'))}</label>${passwordControlHtml('approvedOwnerPassword',{autocomplete:'new-password',locale})}
    <label for="approvedOwnerPasswordConfirm">${esc(t('confirm'))}</label>${passwordControlHtml('approvedOwnerPasswordConfirm',{autocomplete:'new-password',locale})}
    <div id="approvedOwnerError"></div>${authChallengeHtml(locale)}
    <button class="btn" id="approvedOwnerCreate" style="width:100%;margin-top:18px" disabled>${esc(t('create'))}</button>
    ${legalLinks(locale)}</div></div>`;
  bindPasswordVisibility(root);
  let token='',control=null;
  mountTurnstile(AUTH_TURNSTILE_SITE_KEY,{container:'authTurnstile',status:'authTurnstileStatus',
    retry:'authTurnstileRetry',action:'frenly_auth',locale,
    onToken:value=>{token=value;$('approvedOwnerCreate').disabled=!value}})
    .then(value=>control=value);
  $('approvedOwnerCreate').onclick=async()=>{
    const password=$('approvedOwnerPassword').value;
    if(!validNewPassword(password)||password!==$('approvedOwnerPasswordConfirm').value){
      $('approvedOwnerError').innerHTML=`<div class="err">${esc(t('passwordRule'))}</div>`;return;
    }
    $('approvedOwnerCreate').disabled=true;
    const returnUrl=new URL(NestlyNativeBridge.publicUrl('/business'));returnUrl.searchParams.set('invite',inviteToken);
    const {data,error}=await sb.auth.signUp({
      email:invitation.approved_email,password,
      options:{captchaToken:token,emailRedirectTo:returnUrl.toString()}
    });
    token='';
    if(error){
      if(control)control.reset();
      $('approvedOwnerError').innerHTML=`<div class="err">${esc(t('genericError'))}</div>`;$('approvedOwnerCreate').disabled=false;return;
    }
    if(!data.session){
      $('approvedOwnerError').innerHTML=`<div class="err" style="background:#E7F6EE;color:var(--green)">${esc(t('checkEmail'))}</div>`;return;
    }
    route();
  };
}
function renderAuth(mode='in',{admin=false}={}){
  globalThis.document?.documentElement?.setAttribute('lang','en');
  destroyMountedTurnstiles();
  if(!admin&&businessApplicationInviteToken())return renderApprovedBusinessInviteSignup(businessApplicationInviteToken());
  if(!admin&&mode==='up'&&NestlyNativeBridge.isNative)return renderNativeBusinessCompanion();
  if(!admin&&mode==='up')return renderBusinessSignupChoice();
  if(mode==='forgot'){
    root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="authResetTitle">
      <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
      <h1 id="authResetTitle" style="margin:14px 0 2px">Reset your password</h1>
      <p class="muted small" style="margin-top:6px">Enter your account email and we will send a secure reset link.</p>
      <label for="em">Email</label><input id="em" type="email" autocomplete="email" placeholder="you@business.com">
      <div id="autherr"></div>
      ${authChallengeHtml()}
      <div class="row" style="margin-top:18px"><button class="btn" id="resetRequest" disabled>Send reset link</button>
      <span class="spacer"></span><button class="btn ghost sm" id="backSignIn">Back to sign in</button></div>
      ${legalLinks()}</section></main>`;
    let authToken='',authControl=null;
    mountTurnstile(AUTH_TURNSTILE_SITE_KEY,{container:'authTurnstile',status:'authTurnstileStatus',
      retry:'authTurnstileRetry',action:'frenly_auth',
      onToken:(token)=>{authToken=token;$('resetRequest').disabled=!token}})
      .then(control=>authControl=control);
    $('backSignIn').onclick=()=>renderAuth('in',{admin});
    $('resetRequest').onclick=async()=>{
      const email=$('em').value.trim();
      if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)){
        $('autherr').innerHTML='<div class="err">Enter a valid email address.</div>';return;
      }
      if(!authToken) return;
      $('resetRequest').disabled=true;
      const redirect=new URL(NestlyNativeBridge.publicUrl(admin?'/admin':'/business'));
      redirect.searchParams.set('recovery','1');
      try{await sb.auth.resetPasswordForEmail(email,{redirectTo:redirect.toString(),captchaToken:authToken})}catch{}
      /* Turnstile tokens are single-use: clear and reset so a retry gets a fresh challenge. */
      authToken='';if(authControl)authControl.reset();
      $('autherr').innerHTML='<div class="err" style="background:#E7F6EE;color:var(--green)">If an account exists for that email, a reset link is on its way.</div>';
    };
    return;
  }
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="businessAuthTitle">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    ${admin?'':`<nav class="entry-path-switch" aria-label="Account type"><a href="/business" aria-current="page">${CUI.icon('branch',{size:17})}<span>I’m a business</span></a><a href="/app">${CUI.icon('customers',{size:17})}<span>I’m a customer</span></a></nav>`}
    <p class="muted" style="margin-bottom:8px">${admin?'Platform operations for authorized Peekaa administrators.':'Loyalty & retention for every business — real rewards, not vanity points.'}</p>
    <h1 id="businessAuthTitle" style="margin:14px 0 2px">${admin?'Super admin sign in':mode==='in'?'Sign in':'Create your account'}</h1>
    ${!admin&&!NestlyNativeBridge.isNative?`${businessGoogleButtonHtml('businessGoogleSignIn')}<div class="row" aria-hidden="true" style="gap:10px;margin:16px 0 4px"><hr style="flex:1;border:0;border-top:1px solid var(--line)"><span class="muted small">or use email</span><hr style="flex:1;border:0;border-top:1px solid var(--line)"></div>`:''}
    <label for="em">Email</label><input id="em" type="email" placeholder="you@business.com">
    <label for="pw">Password</label>${passwordControlHtml('pw',{autocomplete:mode==='in'?'current-password':'new-password',placeholder:'••••••••'})}
    <div id="autherr">${!admin&&sessionStorage.getItem('nestly-business-oauth-notice')?`<div class="err">${esc(sessionStorage.getItem('nestly-business-oauth-notice'))}</div>`:''}</div>
    ${mode==='in'?'<div style="margin-top:9px;text-align:right"><button class="btn ghost sm" id="forgot" style="border:0;box-shadow:none;padding:4px">Forgot password?</button></div>':''}
    ${authChallengeHtml()}
    <div class="row" style="margin-top:18px">
      <button class="btn" id="go" disabled>${admin?'Sign in':mode==='in'?'Sign in':'Sign up'}</button>
      ${admin?'':`<span class="spacer"></span><button class="btn ghost sm" id="sw">${mode==='in'?'New here? Sign up':'Have an account? Sign in'}</button>`}
    </div>
    ${legalLinks()}</section></main>`;
  bindPasswordVisibility(root);
  if(!admin&&sessionStorage.getItem('nestly-business-oauth-notice'))sessionStorage.removeItem('nestly-business-oauth-notice');
  if(!admin&&NestlyNativeBridge.isNative&&$('sw')){
    $('sw').outerHTML='<span class="muted small" style="max-width:210px;text-align:right">New business accounts cannot be created in this app.</span>';
  }
  let authToken='',authControl=null;
  mountTurnstile(AUTH_TURNSTILE_SITE_KEY,{container:'authTurnstile',status:'authTurnstileStatus',
    retry:'authTurnstileRetry',action:'frenly_auth',
    onToken:(token)=>{authToken=token;$('go').disabled=!token}})
    .then(control=>authControl=control);
  if($('sw'))$('sw').onclick=()=>renderAuth(mode==='in'?'up':'in');
  if($('forgot')) $('forgot').onclick=()=>renderAuth('forgot',{admin});
  if($('businessGoogleSignIn'))$('businessGoogleSignIn').onclick=event=>
    startBusinessGoogleAuth({button:event.currentTarget,errorHostId:'autherr',intent:'signin'});
  $('go').onclick=async()=>{
    const email=$('em').value.trim(),password=$('pw').value;
    if(!authToken) return;
    $('go').disabled=true;
    /* Tokens are single-use: consume, then reset the widget for any follow-up attempt. */
    const captchaToken=authToken;authToken='';
    try{
      if(mode==='up'){
        const {data,error}=await sb.auth.signUp({email,password,options:{captchaToken}});
        if(error) throw error;
        if(!data.session){
          if(authControl)authControl.reset();
          $('autherr').innerHTML='<div class="err">Check your email to confirm your account, then sign in.</div>';return}
      }else{
        const {error}=await sb.auth.signInWithPassword({email,password,options:{captchaToken}});
        if(error) throw error;
      }
      resetClientSessionState({preserveInvitation:true});route();
    }catch(e){
      if(authControl)authControl.reset();
      $('autherr').innerHTML=`<div class="err">${esc(e.message)}</div>`;
    }
  };
}

function validNewPassword(password){
  return password.length>=12 && /[a-z]/.test(password) && /[A-Z]/.test(password)
    && /[0-9]/.test(password) && /[^A-Za-z0-9]/.test(password);
}

/* v188 (owner ruling 2026-08-07): "do not allow firms or users to delete account — it is
   redundant. If they want they can email in their request or speak with their assigned
   consultant." Self-service deletion is gone from every surface; the submit RPC is revoked from
   `authenticated` in the same version, so removing the button is not the only thing stopping it.
   What stays is the ROUTE: the data-request page and the same address the Privacy Notice gives.
   A request already submitted is still shown here — someone who asked before this change must
   not be left wondering what happened to it. */
function accountDeletionCardHtml(){
  /* v189 (owner: "request closure — but hidden inside here, small button"): closing an account is
     a real thing a person came here to do, so it gets a real action rather than a sentence with an
     address buried in it. The button opens a pre-addressed email — Peekaa still decides, which is
     the ruling, but the customer does not have to compose anything or find the address. */
  const closureSubject=encodeURIComponent('Peekaa account closure request');
  const closureBody=encodeURIComponent('I would like to close my Peekaa account.\n\nName:\nPhone or email used:\nBusiness(es) I joined:\n');
  return `<section class="card" id="accountDeletionCard" style="margin-top:14px"><h2>Account &amp; privacy</h2>
    <p class="muted small" style="margin-top:6px">Peekaa handles account closure for you and replies within 30 days. You can also speak to your assigned consultant.</p>
    <div id="accountDeletionStatus" role="status"></div>
    <div class="row" style="margin-top:16px;gap:10px;flex-wrap:wrap">
      <a class="btn" href="mailto:admin.peekaa@gmail.com?subject=${closureSubject}&amp;body=${closureBody}">Request account closure</a>
      <a class="btn ghost" href="/data-request.html">Ask what data is held</a>
    </div>
    <p class="muted small" style="margin-top:12px">Legally required financial, fraud-prevention and security records may be retained after closure.</p>
    <p class="muted small" style="margin-top:4px">Prefer to write yourself? <a href="mailto:admin.peekaa@gmail.com">admin.peekaa@gmail.com</a></p></section>`;
}

/* Shows an EXISTING request's state, if there is one. Never offers a new one. Silent on failure:
   a status panel that cannot load must not imply anything about whether a request exists. */
async function wireAccountDeletionButton(){
  const host=$('accountDeletionStatus');
  if(!host||!S.user)return;
  const {data,error}=await sb.rpc('get_account_deletion_request_v131');
  if(error||!host.isConnected)return;
  const request=Array.isArray(data)?data[0]:data;
  if(!request?.status)return;
  if(['pending','processing'].includes(request.status)){
    const due=request.response_due_at?sgt(request.response_due_at):'within 30 days';
    host.innerHTML=`<div class="imp-note" style="margin-top:14px"><b>Closure request received</b><p class="small" style="margin-top:6px">Peekaa is reviewing it and will reply by ${esc(due)}. Nothing further is needed from you.</p></div>`;
    return;
  }
  if(request.status==='completed'){
    const outcomes={
      deleted_where_permitted:'Deleted where permitted',
      anonymised_where_permitted:'Anonymised where permitted',
      retained_legal:'Retained under legal obligation',
      request_invalid:'Request invalid after identity review'
    };
    host.innerHTML=`<div class="imp-note" style="margin-top:14px"><b>Closure request reviewed</b><p class="small" style="margin-top:6px">${esc(outcomes[request.resolution_code]||'Reviewed outcome recorded')}.</p></div>`;
  }
}

function renderPasswordUpdate(){
  globalThis.document?.documentElement?.setAttribute('lang','en');
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="passwordUpdateTitle">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    <h1 id="passwordUpdateTitle" style="margin:14px 0 2px">Choose a new password</h1>
    <p class="muted small" style="margin-top:6px">Use at least 12 characters with upper and lowercase letters, a number and a symbol.</p>
    <label for="newPw">New password</label>${passwordControlHtml('newPw',{autocomplete:'new-password'})}
    <label for="confirmPw">Confirm new password</label>${passwordControlHtml('confirmPw',{autocomplete:'new-password'})}
    <div id="autherr"></div><button class="btn" id="savePw" style="width:100%;margin-top:18px">Update password</button>
    ${legalLinks()}</section></main>`;
  bindPasswordVisibility(root);
  $('savePw').onclick=async()=>{
    const password=$('newPw').value;
    if(!validNewPassword(password)){
      $('autherr').innerHTML='<div class="err">Use at least 12 characters with upper and lowercase letters, a number and a symbol.</div>';return;
    }
    if(password!==$('confirmPw').value){$('autherr').innerHTML='<div class="err">Passwords do not match.</div>';return}
    $('savePw').disabled=true;
    const {error}=await sb.auth.updateUser({password});
    if(error){$('autherr').innerHTML='<div class="err">This reset link is invalid or expired. Request a new one.</div>';$('savePw').disabled=false;return}
    await sb.auth.signOut();passwordRecoveryActive=false;resetClientSessionState();
    history.replaceState(null,'',location.pathname+'#/');
    renderAuth('in',{admin:entryRouteForLocation().startsWith('#/platform')});
    $('autherr').innerHTML='<div class="err" style="background:#E7F6EE;color:var(--green)">Password updated. Sign in with your new password.</div>';
  };
}

function renderRecoveryInvalid(){
  globalThis.document?.documentElement?.setAttribute('lang','en');
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="recoveryInvalidTitle">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    <h1 id="recoveryInvalidTitle" style="margin:14px 0 2px">Reset link unavailable</h1>
    <p class="muted small" style="margin-top:6px">This password reset link is invalid or expired. Request a new link to continue.</p>
    <button class="btn" id="requestAnotherReset" style="width:100%;margin-top:18px">Request a new reset link</button>
    ${legalLinks()}</section></main>`;
  $('requestAnotherReset').onclick=()=>{passwordRecoveryError=false;renderAuth('forgot')};
}

sb.auth.onAuthStateChange((event,session)=>{
  globalThis.NestlyCustomerPush?.setAuthenticatedUser?.(session?.user?.id||'');
  if(event==='PASSWORD_RECOVERY'){
    passwordRecoveryError=false;passwordRecoveryActive=true;
    setTimeout(()=>renderPasswordUpdate(),0);
  }
  if(event==='SIGNED_OUT'){setTimeout(()=>route(),0)}
});

async function consumeBusinessOAuthRedirect(){
  const search=new URLSearchParams(location.search);
  if(search.get('oauth')!=='business')return;
  const hash=new URLSearchParams((location.hash||'').replace(/^#/,'').replace(/^\?/,'') );
  const providerError=search.get('error_description')||search.get('error')||hash.get('error_description')||hash.get('error');
  const oauthAccessToken=hash.get('access_token'),oauthRefreshToken=hash.get('refresh_token');
  /* OAuth fragments contain credentials. Remove them from browser history before
     any network or rendering work, then establish only the Supabase session.
     Business authority remains server-derived after route() loads the persona. */
  history.replaceState(null,'','/business');
  const pendingAttempt=takeBusinessGoogleOAuthAttempt();
  if(!pendingAttempt||providerError){
    sessionStorage.setItem('nestly-business-oauth-notice','Could not complete Google sign-in');
    return;
  }
  if(!oauthAccessToken||!oauthRefreshToken){
    sessionStorage.setItem('nestly-business-oauth-notice','Could not complete Google sign-in');
    return;
  }
  try{
    const admissionClient=createBusinessOAuthAdmissionClient();
    const {error}=await admissionClient.auth.setSession({access_token:oauthAccessToken,refresh_token:oauthRefreshToken});
    if(error)throw error;
    const {data:admission,error:admissionError}=await admissionClient.rpc('complete_business_google_oauth_v138',{
      p_intent:pendingAttempt.intent,p_attempt_token:pendingAttempt.attemptToken
    });
    if(admissionError||admission?.admitted!==true)throw admissionError||new Error('Google OAuth admission was not confirmed');
    /* Persist only the exact provider session that the server has admitted. */
    const {error:persistError}=await sb.auth.setSession({access_token:oauthAccessToken,refresh_token:oauthRefreshToken});
    if(persistError)throw persistError;
  }catch{
    await sb.auth.signOut({scope:'local'}).catch(()=>{});
    sessionStorage.setItem('nestly-business-oauth-notice',pendingAttempt.intent==='signin'
      ?'No business account was found for that Google login. Choose New here? Sign up and accept the Terms and Privacy Policy first.'
      :'Could not verify the consented Google signup. Return to signup and try again.');
  }
}

async function consumePasswordRecoveryRedirect(){
  const search=new URLSearchParams(location.search);
  const hash=new URLSearchParams((location.hash||'').replace(/^#/,''));
  if(hash.get('type')==='recovery'&&hash.get('access_token')&&hash.get('refresh_token')){
    const accessToken=hash.get('access_token'),refreshToken=hash.get('refresh_token');
    history.replaceState(null,'',location.pathname+'?recovery=1#/recover');
    try{
      const {error}=await sb.auth.setSession({access_token:accessToken,refresh_token:refreshToken});
      passwordRecoveryError=!!error;passwordRecoveryActive=!error;
    }catch{passwordRecoveryError=true;passwordRecoveryActive=false}
  }else if(search.get('recovery')==='1'){
    const {data:{session}}=await sb.auth.getSession();
    passwordRecoveryActive=!!session;passwordRecoveryError=!session;
  }
}

/* ============================================================================
   Universal importer — paste-from-Excel (TSV), CSV, or .xlsx upload → any module.
   One engine, per-module config. Excel "copy cells" pastes tab-separated, so paste
   and file share the same row/column pipeline. Inserts row-by-row (chunked) so one
   bad/duplicate row is skipped, never failing the whole batch.
   ============================================================================ */
const IMPORT_CONFIGS={
  customers:{title:'Customers',table:'clients',
    hint:'Columns we recognise: name (required), phone, email, birthday (YYYY-MM-DD), notes. Duplicates (same phone) are skipped.',
    fields:[
      {key:'full_name',aliases:['name','full name','fullname','customer','client'],required:true},
      {key:'phone',aliases:['phone','mobile','contact','hp','number','tel']},
      {key:'email',aliases:['email','e-mail','mail']},
      {key:'birth_date',aliases:['birthday','birth date','birth','dob']},
      {key:'notes',aliases:['notes','note','remark','remarks']}],
    build:o=>({business_id:S.biz.id,...o})},
  services:{title:'Services',table:'services',
    hint:'Columns: name (required), price (in dollars), duration/mins, category, description.',
    fields:[
      {key:'name',aliases:['name','service'],required:true},
      {key:'price_cents',aliases:['price','price (sgd)','amount','cost'],money:true},
      {key:'duration_min',aliases:['duration','mins','minutes','time','duration (minutes)'],int:true,def:60},
      {key:'category',aliases:['category','type','group']},
      {key:'description',aliases:['description','desc','details']}],
    build:o=>({business_id:S.biz.id,active:true,...o})},
  inventory:{title:'Products',table:'products',
    hint:'Columns: name (required), sku, price/retail (in dollars), and optionally qty/stock for an opening batch.',
    fields:[
      {key:'name',aliases:['name','product','item'],required:true},
      {key:'sku',aliases:['sku','code','barcode','ref']},
      {key:'retail_price_cents',aliases:['price','retail','retail price','price (sgd)','amount','cost'],money:true},
      {key:'opening_qty',aliases:['qty','quantity','stock','on hand','opening stock','count'],int:true,stripField:true}],
    build:o=>({business_id:S.biz.id,...o})},
  staff:{title:'Team members',table:'staff',
    hint:'Columns: name (required), email, phone, title, role, calendar_color. Imported people are roster records; invite them separately if they need to sign in.',
    fields:[
      {key:'full_name',aliases:['name','full name','fullname','staff','employee'],required:true},
      {key:'email',aliases:['email','e-mail','mail']},
      {key:'phone',aliases:['phone','mobile','contact','tel']},
      {key:'title',aliases:['title','job title','position']},
      {key:'role',aliases:['role','access role'],def:'staff'},
      {key:'calendar_color',aliases:['calendar color','calendar colour','color','colour'],def:'#7C9CBF'}],
    build:o=>({business_id:S.biz.id,active:true,...o})},
  branches:{title:'Branches',table:'branches',
    hint:'Columns: name (required), address, phone, email, timezone. Asia/Singapore is used when timezone is blank.',
    fields:[
      {key:'name',aliases:['name','branch','location','outlet'],required:true},
      {key:'address',aliases:['address','location address']},
      {key:'phone',aliases:['phone','contact','tel']},
      {key:'email',aliases:['email','e-mail']},
      {key:'timezone',aliases:['timezone','time zone'],def:'Asia/Singapore'}],
    build:o=>({business_id:S.biz.id,active:true,...o})},
  reservations:{title:'Tables / capacity',table:'booking_tables',
    hint:'Columns: name (required), pax/seats, quantity, sort. Use one row per table type or capacity pool.',
    fields:[
      {key:'name',aliases:['name','table','table type','capacity type'],required:true},
      {key:'pax',aliases:['pax','seats','party size'],int:true},
      {key:'quantity',aliases:['quantity','qty','count','number'],int:true,def:1},
      {key:'sort',aliases:['sort','order','position'],int:true,def:0}],
    build:o=>({business_id:S.biz.id,active:true,...o})},
};
/* Parse pasted/file text into array-of-arrays. Auto-detects tab (Excel paste) vs comma (CSV),
   honours quoted fields + embedded newlines. */
function parseDelimited(text){
  const head=(text.split(/\r?\n/)[0]||'');
  const delim=(head.split('\t').length>head.split(',').length)?'\t':',';
  const rows=[];let cur=[''],q=false;
  for(let i=0;i<text.length;i++){const ch=text[i];
    if(q){ if(ch==='"'){ if(text[i+1]==='"'){cur[cur.length-1]+='"';i++} else q=false } else cur[cur.length-1]+=ch; }
    else if(ch==='"')q=true;
    else if(ch===delim)cur.push('');
    else if(ch==='\n'||ch==='\r'){ if(ch==='\r'&&text[i+1]==='\n')i++; if(cur.length>1||cur[0]!==''){rows.push(cur);cur=['']} }
    else cur[cur.length-1]+=ch;
  }
  if(cur.length>1||cur[0]!=='')rows.push(cur);
  return rows;
}
/* rows(array-of-arrays) + config → {recs:[{payload,mapped}], skipped, total, missing} */
function mapRows(rows,cfg){
  if(!rows||rows.length<2) return {recs:[],skipped:0,total:0,missing:null};
  const hdr=rows[0].map(h=>String(h||'').trim().toLowerCase());
  const idx={};let missingReq=null;
  for(const f of cfg.fields){
    let i=hdr.findIndex(h=>f.aliases.includes(h));
    if(i<0) i=hdr.findIndex(h=>h&&f.aliases.some(a=>h.includes(a)));
    idx[f.key]=i;
    if(f.required&&i<0) missingReq=f.aliases[0];
  }
  if(missingReq) return {recs:[],skipped:0,total:rows.length-1,missing:missingReq};
  const recs=[];let skipped=0;
  for(const r of rows.slice(1)){
    if(r.every(c=>!String(c||'').trim())) continue; // blank line
    const mapped={};let ok=true;
    for(const f of cfg.fields){
      const i=idx[f.key];let raw=i>=0?String(r[i]??'').trim():'';
      let val=raw;
      if(f.money) val=raw?Math.round(parseFloat(raw.replace(/[^0-9.\-]/g,''))*100):0;
      else if(f.int) val=raw?parseInt(raw.replace(/[^0-9\-]/g,'')):(f.def??null);
      else if(f.transform) val=raw?f.transform(raw):null;
      else val=raw||null;
      if(f.required&&(!val||String(val).length<2)){ok=false;break}
      if(val!==null&&val!==undefined&&val!=='') mapped[f.key]=val;
      else if(f.def!==undefined) mapped[f.key]=f.def;
    }
    if(!ok){skipped++;continue}
    recs.push({payload:cfg.build({...mapped}),mapped});
  }
  return {recs,skipped,total:rows.length-1,missing:null};
}
async function runImport(recs,entity,idempotencyKey,onProgress){
  if(onProgress) onProgress(0,recs.length,'Validating');
  const {data:staged,error:stageError}=await sb.rpc('stage_import_rows',{
    p_business:S.biz.id,p_entity:entity,p_rows:recs.map(r=>r.mapped),
    p_idempotency_key:idempotencyKey});
  if(stageError) return {inserted:0,failed:recs.length,errs:[stageError.message],blocked:true};
  const rowErrors=(staged.errors||[]).map(e=>`Row ${e.row_number}: ${(e.errors||[]).join(', ')}`);
  if(staged.invalid>0) return {inserted:0,failed:staged.invalid,errs:rowErrors,blocked:true};
  if(onProgress) onProgress(recs.length,recs.length,'Saving');
  const {data:done,error:commitError}=await sb.rpc('commit_import_job',{p_job:staged.job_id});
  if(commitError) return {inserted:0,failed:recs.length,errs:[commitError.message],blocked:true};
  return {inserted:done.imported,failed:0,errs:[],blocked:false};
}
/* The modal. moduleKey ∈ customers|services|inventory. onDone() re-renders the caller. */
window.openImport=function(moduleKey,onDone){
  const cfg=IMPORT_CONFIGS[moduleKey];if(!cfg)return;
  let mode='paste',parsed=null,importIdem=null;
  const wrap=document.createElement('div');wrap.className='modal';wrap.id='impModal';wrap.tabIndex=-1;
  wrap.setAttribute('role','dialog');wrap.setAttribute('aria-modal','true');wrap.setAttribute('aria-labelledby','impTitle');
  document.body.appendChild(wrap);
  let deactivateDialog;
  const close=()=>deactivateDialog?deactivateDialog():wrap.remove();
  function render(){
    wrap.innerHTML=`<div class="modal-card">
      <div class="row"><h2 id="impTitle" style="font-size:1.3rem">${CUI.icon('import',{size:21})} <span data-workspace-i18n>Import</span> <span data-workspace-i18n>${esc(cfg.title)}</span></h2><span class="spacer"></span>
        <button class="btn ghost sm" id="impX">Close</button></div>
      <div class="imp-note">${esc(cfg.hint)}</div>
      <div style="margin:16px 0 6px"><div class="seg">
        <button class="${mode==='paste'?'act':''}" data-m="paste">Paste from Excel</button>
        <button class="${mode==='file'?'act':''}" data-m="file">Upload file</button></div></div>
      ${mode==='paste'
        ? `<label for="impText">Copy the cells in Excel/Sheets (including the header row) and paste here</label>
           <textarea id="impText" rows="7" placeholder="name&#9;phone&#9;email&#10;Jane Tan&#9;9123 4567&#9;jane@mail.com" style="font-family:ui-monospace,monospace;font-size:12.5px"></textarea>
           <div style="margin-top:12px"><button class="btn sm" id="impParse">Preview</button></div>`
        : `<label for="impFile">Choose a .csv or .xlsx file (first row = headers)</label>
           <input type="file" id="impFile" accept=".csv,.tsv,.xlsx,.xls,text/csv">`}
      <div id="impResult"></div>
    </div>`;
    $('impX').onclick=close;
    wrap.querySelectorAll('[data-m]').forEach(b=>b.onclick=()=>{mode=b.dataset.m;parsed=null;render()});
    if(mode==='paste'){
      $('impParse').onclick=()=>{ const t=$('impText').value; if(!t.trim())return toast('Paste some rows first'); preview(parseDelimited(t)); };
    }else{
      $('impFile').onchange=async ev=>{
        const f=ev.target.files[0];if(!f)return;
        try{
          if(/\.x(lsx|ls)$/i.test(f.name)){
            await loadSpreadsheetLibrary();
            const buf=await f.arrayBuffer();const wb=XLSX.read(buf,{type:'array'});
            const sheet=wb.Sheets[wb.SheetNames[0]];
            preview(XLSX.utils.sheet_to_json(sheet,{header:1,blankrows:false,raw:false}));
          }else{ preview(parseDelimited(await f.text())); }
        }catch(e){fail(e)}
      };
    }
  }
  function preview(rows){
    importIdem=null;
    parsed=mapRows(rows,cfg);
    const R=$('impResult');
    if(parsed.missing){R.innerHTML=`<div class="err">Couldn't find a <b>${esc(parsed.missing)}</b> column. Make sure your first row has headers.</div>`;return}
    if(!parsed.recs.length){R.innerHTML=`<div class="err">${workspaceTemplateHtmlV97(parsed.skipped?'noValidImportRowsSkipped':'noValidImportRows',{skipped:parsed.skipped})}</div>`;return}
    const cols=cfg.fields.filter(f=>!f.stripField).map(f=>f.key);
    const show=parsed.recs.slice(0,4);
    R.innerHTML=`<div class="imp-prev"><table><tr>${cols.map(c=>`<th>${esc(c.replace('_cents','').replace('_',' '))}</th>`).join('')}</tr>
      ${show.map(rec=>`<tr>${cols.map(c=>{let v=rec.payload[c];if(c.endsWith('_cents'))v=v!=null?money(v):'';return `<td>${esc(v??'')}</td>`}).join('')}</tr>`).join('')}</table></div>
      <p class="small muted" style="margin-top:8px">${workspaceTemplateHtmlV97(parsed.skipped?'importRowsReadySkipped':'importRowsReady',{ready:parsed.recs.length,skipped:parsed.skipped,shown:show.length})}</p>
      <div style="margin-top:12px"><button class="btn" id="impGo"><span data-workspace-i18n>Import</span> <span data-merchant-content>${parsed.recs.length}</span> <span data-workspace-i18n>${esc(cfg.title)}</span></button></div>`;
    $('impGo').onclick=async()=>{
      $('impGo').disabled=true;$('impGo').textContent='Importing…';
      if(!importIdem) importIdem=crypto.randomUUID();
      const {inserted,failed,errs,blocked}=await runImport(parsed.recs,moduleKey,importIdem,(d,t,stage)=>{$('impGo').innerHTML=`<span data-workspace-i18n>${esc(stage)}</span>… <span data-merchant-content>${d}/${t}</span>`});
      R.innerHTML=`<div class="imp-note" style="${blocked?'background:#FFF1EF;color:#9D352C':'background:#E7F6EE;color:#1f7a4d'}">${blocked?'Nothing imported. Correct the source data, then start the import again.':`<span data-workspace-i18n>✓ Imported</span> <b data-merchant-content>${inserted}</b> <span data-workspace-i18n>${esc(cfg.title)}</span>.`}</div>
        ${errs.length?`<p class="small muted" style="margin-top:8px"><span data-workspace-i18n>First issues:</span> <span data-merchant-content>${errs.map(e=>esc(e)).join('; ')}</span></p>`:''}
        <div style="margin-top:14px"><button class="btn sm" id="impDone">${blocked?'Close':'Done'}</button></div>`;
      $('impDone').onclick=()=>{close();if(onDone)onDone()};
    };
  }
  render();
  deactivateDialog=CUI.activateDialog(wrap,{onClose:close,initialFocus:'#impX'});
};
function killChannels(){
  if(rtChannel){ try{sb.removeChannel(rtChannel);}catch(e){} }
  rtChannel=null;rtChannelBizId=null;
}
/* v97 translates Peekaa's workspace interface only. Merchant-entered records remain
   canonical data, and customer surfaces are intentionally English-only. */
const WORKSPACE_LOCALES_V97=Object.freeze(['en','zh-CN','ms']);
let workspaceLocale='en',workspaceLocaleVersion=0,workspaceLocaleLoadedFor='',workspaceLocalizationObserver=null;
/* v185: the tables live in the lazily loaded i18n chunk. `typeof` is safe on an identifier that
   has not been declared yet, and returning the source text is the same behaviour as English. */
const workspaceTranslationV97=source=>workspaceLocale==='en'||typeof WORKSPACE_GENERATED_COPY_V97==='undefined'
  ?source
  :(WORKSPACE_COPY_V97[workspaceLocale]?.[source]??WORKSPACE_GENERATED_COPY_V97[workspaceLocale]?.[source]??source);
const WORKSPACE_TEMPLATE_COPY_V97=Object.freeze({
  customerPagination:Object.freeze({en:'{total} customers · page {page} of {pages}','zh-CN':'{total} 位顾客 · 第 {page} 页，共 {pages} 页',ms:'{total} pelanggan · halaman {page} daripada {pages}'}),
  completedTransaction:Object.freeze({en:'{count} completed transaction','zh-CN':'{count} 笔已完成交易',ms:'{count} transaksi selesai'}),
  completedTransactions:Object.freeze({en:'{count} completed transactions','zh-CN':'{count} 笔已完成交易',ms:'{count} transaksi selesai'}),
  scopePeriod:Object.freeze({en:'{branch} · {from} to {to}','zh-CN':'{branch} · {from} 至 {to}',ms:'{branch} · {from} hingga {to}'}),
  allBranchesPeriod:Object.freeze({en:'All permitted branches · {from} to {to}','zh-CN':'所有获准分店 · {from} 至 {to}',ms:'Semua cawangan yang dibenarkan · {from} hingga {to}'}),
  performancePeriodRange:Object.freeze({en:'{from} to {to}','zh-CN':'{from} 至 {to}',ms:'{from} hingga {to}'}),
  pointCostDerived:Object.freeze({en:'Cost per point: {cost}. Every reward uses this to work out its point price.','zh-CN':'每积分成本：{cost}。每个奖励都以此计算其积分价格。',ms:'Kos setiap mata: {cost}. Setiap ganjaran menggunakannya untuk mengira harga matanya.'}),
  parkExpiryPreview:Object.freeze({en:'Expires {expires} · {days} days','zh-CN':'于 {expires} 到期 · {days} 天',ms:'Luput {expires} · {days} hari'}),
  parkExpiryPreviewTier:Object.freeze({en:'Expires {expires} · {days} days · {tier}','zh-CN':'于 {expires} 到期 · {days} 天 · {tier}',ms:'Luput {expires} · {days} hari · {tier}'}),
  parkKeptUntil:Object.freeze({en:'Kept until {date}','zh-CN':'保留至 {date}',ms:'Disimpan hingga {date}'}),
  sortByAscending:Object.freeze({en:'Sort by {label}, ascending','zh-CN':'按{label}升序排序',ms:'Isih ikut {label}, menaik'}),
  sortByDescending:Object.freeze({en:'Sort by {label}, descending','zh-CN':'按{label}降序排序',ms:'Isih ikut {label}, menurun'}),
  bottlePercentLeft:Object.freeze({en:'{percent}% left','zh-CN':'剩余 {percent}%',ms:'{percent}% berbaki'}),
  bookingRequestWaiting:Object.freeze({en:'{count} booking request is waiting for a decision.','zh-CN':'{count} 个预约请求等待处理。',ms:'{count} permintaan tempahan menunggu keputusan.'}),
  bookingRequestsWaitingMany:Object.freeze({en:'{count} booking requests are waiting for a decision.','zh-CN':'{count} 个预约请求等待处理。',ms:'{count} permintaan tempahan menunggu keputusan.'}),
  bookingRequestsBadge:Object.freeze({en:'Booking requests — {count} waiting','zh-CN':'预约请求 — {count} 个等待中',ms:'Permintaan tempahan — {count} menunggu'}),
  staffKeptHasRecord:Object.freeze({en:'{name} has {count} record of work here, so the record is kept. Use Deactivate to stop their access.','zh-CN':'{name} 在此有 {count} 条工作记录，因此保留该记录。请使用停用来停止其访问权限。',ms:'{name} mempunyai {count} rekod kerja di sini, jadi rekod itu dikekalkan. Gunakan Nyahaktif untuk menghentikan aksesnya.'}),
  staffKeptHasRecords:Object.freeze({en:'{name} has {count} records of work here, so the record is kept. Use Deactivate to stop their access.','zh-CN':'{name} 在此有 {count} 条工作记录，因此保留该记录。请使用停用来停止其访问权限。',ms:'{name} mempunyai {count} rekod kerja di sini, jadi rekod itu dikekalkan. Gunakan Nyahaktif untuk menghentikan aksesnya.'}),
  scopeCustomers:Object.freeze({en:'Showing {shown} of {total} customers for this scope.','zh-CN':'此范围显示 {shown}／{total} 位顾客。',ms:'Menunjukkan {shown} daripada {total} pelanggan untuk skop ini.'}),
  customerRecordExported:Object.freeze({en:'{count} customer record exported with no silent truncation.','zh-CN':'已完整导出 {count} 条顾客记录。',ms:'{count} rekod pelanggan dieksport tanpa pemotongan senyap.'}),
  customerRecordsExported:Object.freeze({en:'{count} customer records exported with no silent truncation.','zh-CN':'已完整导出 {count} 条顾客记录。',ms:'{count} rekod pelanggan dieksport tanpa pemotongan senyap.'}),
  customersShown:Object.freeze({en:'{count} customers shown','zh-CN':'已显示 {count} 位顾客',ms:'{count} pelanggan ditunjukkan'}),
  importBooking:Object.freeze({en:'Import {count} booking','zh-CN':'导入 {count} 个预订',ms:'Import {count} tempahan'}),
  importBookings:Object.freeze({en:'Import {count} bookings','zh-CN':'导入 {count} 个预订',ms:'Import {count} tempahan'}),
  bookingsReady:Object.freeze({en:'{ready} bookings ready (of {rows} rows).','zh-CN':'{rows} 行中有 {ready} 个预订可导入。',ms:'{ready} tempahan sedia (daripada {rows} baris).'}),
  firstBookings:Object.freeze({en:'First: {bookings}…','zh-CN':'首批：{bookings}…',ms:'Pertama: {bookings}…'}),
  importBookingPreview:Object.freeze({en:'✓ Imported {inserted}, skipped {skipped}.','zh-CN':'✓ 已导入 {inserted} 个，跳过 {skipped} 个。',ms:'✓ {inserted} diimport, {skipped} dilangkau.'}),
  firstImportError:Object.freeze({en:'First {count} error:','zh-CN':'首 {count} 个错误：',ms:'{count} ralat pertama:'}),
  firstImportErrors:Object.freeze({en:'First {count} errors:','zh-CN':'前 {count} 个错误：',ms:'{count} ralat pertama:'}),
  importedBooking:Object.freeze({en:'Imported {count} booking — review it above as pending','zh-CN':'已导入 {count} 个预订，请在上方审核待处理项目',ms:'{count} tempahan diimport — semak sebagai belum selesai di atas'}),
  importedBookings:Object.freeze({en:'Imported {count} bookings — review them above as pending','zh-CN':'已导入 {count} 个预订，请在上方审核待处理项目',ms:'{count} tempahan diimport — semak sebagai belum selesai di atas'}),
  importCustomers:Object.freeze({en:'Import {count} customers','zh-CN':'导入 {count} 位顾客',ms:'Import {count} pelanggan'}),
  customersReady:Object.freeze({en:'{ready} customers ready (of {rows} rows).','zh-CN':'{rows} 行中有 {ready} 位顾客可导入。',ms:'{ready} pelanggan sedia (daripada {rows} baris).'}),
  firstCustomers:Object.freeze({en:'First: {customers}…','zh-CN':'首批：{customers}…',ms:'Pertama: {customers}…'}),
  noValidImportRows:Object.freeze({en:'No valid rows found.','zh-CN':'未找到有效行。',ms:'Tiada baris yang sah ditemui.'}),
  noValidImportRowsSkipped:Object.freeze({en:'No valid rows found ({skipped} skipped — missing a name).','zh-CN':'未找到有效行（跳过 {skipped} 行——缺少姓名）。',ms:'Tiada baris yang sah ditemui ({skipped} dilangkau — nama tiada).'}),
  importRowsReady:Object.freeze({en:'{ready} ready to import. Showing first {shown}.','zh-CN':'{ready} 行可导入。显示前 {shown} 行。',ms:'{ready} sedia untuk diimport. Menunjukkan {shown} yang pertama.'}),
  importRowsReadySkipped:Object.freeze({en:'{ready} ready to import · {skipped} skipped (no name). Showing first {shown}.','zh-CN':'{ready} 行可导入 · 跳过 {skipped} 行（无姓名）。显示前 {shown} 行。',ms:'{ready} sedia untuk diimport · {skipped} dilangkau (tiada nama). Menunjukkan {shown} yang pertama.'}),
  requestStatus:Object.freeze({en:'Request {status}','zh-CN':'请求状态：{status}',ms:'Status permintaan: {status}'}),
  adjustedBalance:Object.freeze({en:'Adjusted — new balance {balance} pts (audited)','zh-CN':'已调整——新余额为 {balance} 分（已审计）',ms:'Dilaraskan — baki baharu {balance} mata (diaudit)'}),
  itemAdded:Object.freeze({en:'{item} added','zh-CN':'已添加 {item}',ms:'{item} ditambah'}),
  itemSelected:Object.freeze({en:'{item} selected','zh-CN':'已选择 {item}',ms:'{item} dipilih'}),
  bookedWith:Object.freeze({en:'Booked with {staff}','zh-CN':'已预约 {staff}',ms:'Ditempah dengan {staff}'}),
  newReturn:Object.freeze({en:'{count} new return recorded','zh-CN':'已记录 {count} 位新回流顾客',ms:'{count} pelanggan kembali baharu direkodkan'}),
  newReturns:Object.freeze({en:'{count} new returns recorded','zh-CN':'已记录 {count} 位新回流顾客',ms:'{count} pelanggan kembali baharu direkodkan'}),
  measurementStarted:Object.freeze({en:'Measurement started','zh-CN':'衡量已开始',ms:'Pengukuran telah bermula'}),
  measurementStartedEnds:Object.freeze({en:'Measurement started · ends {ends}','zh-CN':'衡量已开始 · 于 {ends} 结束',ms:'Pengukuran telah bermula · tamat {ends}'}),
  receiptConfirmationRecorded:Object.freeze({en:'{count} manual receipt confirmation recorded','zh-CN':'已记录 {count} 项手动收讫确认',ms:'{count} pengesahan penerimaan manual direkodkan'}),
  receiptConfirmationsRecorded:Object.freeze({en:'{count} manual receipt confirmations recorded','zh-CN':'已记录 {count} 项手动收讫确认',ms:'{count} pengesahan penerimaan manual direkodkan'}),
  receiptConfirmationFailed:Object.freeze({en:'{count} confirmation could not be recorded. Retry the same selected customer.','zh-CN':'有 {count} 项确认无法记录。请重试同一位已选顾客。',ms:'{count} pengesahan tidak dapat direkodkan. Cuba semula pelanggan terpilih yang sama.'}),
  receiptConfirmationsFailed:Object.freeze({en:'{count} confirmations could not be recorded. Retry the same selected customers.','zh-CN':'有 {count} 项确认无法记录。请重试相同的已选顾客。',ms:'{count} pengesahan tidak dapat direkodkan. Cuba semula pelanggan terpilih yang sama.'}),
  exposureRetryChannelLocked:Object.freeze({en:'This retry is locked to {channel} because that is the channel you originally confirmed. Choose that channel, or close and start a separate new attempt.','zh-CN':'此重试已锁定为 {channel}，因为这是您最初确认的渠道。请选择该渠道，或关闭后另行开始新的尝试。',ms:'Cubaan semula ini dikunci kepada {channel} kerana itulah saluran yang anda sahkan pada asalnya. Pilih saluran itu, atau tutup dan mulakan cubaan baharu yang berasingan.'}),
  exposureRetryMixedChannels:Object.freeze({en:'Selected retries use different confirmed channels. Retry one channel group at a time.','zh-CN':'所选重试使用不同的已确认渠道。请每次仅重试一个渠道组。',ms:'Cubaan semula yang dipilih menggunakan saluran pengesahan yang berbeza. Cuba semula satu kumpulan saluran pada satu masa.'}),
  packageVersionCreated:Object.freeze({en:'New package version v{version} created; prior version archived','zh-CN':'已创建配套新版本 v{version}；旧版本已归档',ms:'Versi pakej baharu v{version} dicipta; versi terdahulu diarkibkan'}),
  giftCardLoaded:Object.freeze({en:'{amount} loaded onto account 🎉','zh-CN':'已将 {amount} 存入账户 🎉',ms:'{amount} dimasukkan ke dalam akaun 🎉'}),
  /* v215: the welcome offer names the item that was handed over, so staff and customer are
     looking at the same words. Interpolated runtime copy has to be a reviewed template. */
  welcomeOfferGiven:Object.freeze({en:'{item} given free — welcome offer used ✓','zh-CN':'已免费赠送 {item} —— 迎新礼遇已使用 ✓',ms:'{item} diberi percuma — tawaran selamat datang digunakan ✓'}),
  sessionUsed:Object.freeze({en:'Session used — {remaining} left. Visit counted for retention ✓','zh-CN':'已使用一次——剩余 {remaining} 次。此次到访已计入回流统计 ✓',ms:'Sesi digunakan — baki {remaining}. Lawatan dikira untuk pengekalan ✓'}),
  catalogueEnabled:Object.freeze({en:'Catalogue-first checkout enabled','zh-CN':'已启用目录优先结账',ms:'Pembayaran katalog dahulu diaktifkan'}),
  catalogueDisabled:Object.freeze({en:'Catalogue-first checkout disabled','zh-CN':'已停用目录优先结账',ms:'Pembayaran katalog dahulu dinyahaktifkan'}),
  inviteCreated:Object.freeze({en:'Invite created: {code} — copied','zh-CN':'邀请已创建：{code}——已复制',ms:'Jemputan dicipta: {code} — disalin'}),
  importPartial:Object.freeze({en:'Imported {count}, then failed: {error}','zh-CN':'已导入 {count} 个，随后失败：{error}',ms:'{count} diimport, kemudian gagal: {error}'}),
  customersImported:Object.freeze({en:'Imported {count} customers 🎉','zh-CN':'已导入 {count} 位顾客 🎉',ms:'{count} pelanggan diimport 🎉'}),
  customersImportPreview:Object.freeze({en:'✓ {count} imported.','zh-CN':'✓ 已导入 {count} 个。',ms:'✓ {count} diimport.'}),
  packageHistory:Object.freeze({en:'Showing the newest {shown} of {total} accessible package-session rows (server limit {limit}).','zh-CN':'显示最新 {shown}／{total} 条可访问的配套次数记录（服务器上限 {limit}）。',ms:'Menunjukkan {shown} daripada {total} rekod sesi pakej terbaharu yang boleh diakses (had pelayan {limit}).'}),
  packageHistoryWithOlder:Object.freeze({en:'Showing the newest {shown} of {total} accessible package-session rows (server limit {limit}) · older rows are not shown.','zh-CN':'显示最新 {shown}／{total} 条可访问的配套次数记录（服务器上限 {limit}）· 较早记录未显示。',ms:'Menunjukkan {shown} daripada {total} rekod sesi pakej terbaharu yang boleh diakses (had pelayan {limit}) · rekod lebih lama tidak dipaparkan.'}),
  appointmentChanged:Object.freeze({en:'{result}.{confirmation}','zh-CN':'{result}。{confirmation}',ms:'{result}. {confirmation}'}),
  appointmentStatus:Object.freeze({en:'Appointment {status}','zh-CN':'预约状态：{status}',ms:'Status janji temu: {status}'}),
  exactSnapshotMismatch:Object.freeze({en:'The fixed snapshot expected {expected} records but returned {actual}. No partial CSV was downloaded.','zh-CN':'固定快照应有 {expected} 条记录，但只返回 {actual} 条。未下载不完整 CSV。',ms:'Syot kilat tetap menjangka {expected} rekod tetapi mengembalikan {actual}. CSV separa tidak dimuat turun.'}),
  qrReady:Object.freeze({en:'QR ready. Download it before leaving this page.','zh-CN':'二维码已就绪。请在离开此页面前下载。',ms:'QR sedia. Muat turun sebelum meninggalkan halaman ini.'}),
  qrReadyExpires:Object.freeze({en:'QR ready · expires {expires}. Download it before leaving this page.','zh-CN':'二维码已就绪 · {expires} 到期。请在离开此页面前下载。',ms:'QR sedia · tamat tempoh {expires}. Muat turun sebelum meninggalkan halaman ini.'}),
  qrReadyRevoked:Object.freeze({en:'QR ready · {count} older QR revoked. Download it before leaving this page.','zh-CN':'二维码已就绪 · 已撤销 {count} 个旧二维码。请在离开此页面前下载。',ms:'QR sedia · {count} QR lama dibatalkan. Muat turun sebelum meninggalkan halaman ini.'}),
  qrReadyQrsRevoked:Object.freeze({en:'QR ready · {count} older QRs revoked. Download it before leaving this page.','zh-CN':'二维码已就绪 · 已撤销 {count} 个旧二维码。请在离开此页面前下载。',ms:'QR sedia · {count} QR lama dibatalkan. Muat turun sebelum meninggalkan halaman ini.'}),
  qrReadyExpiresRevoked:Object.freeze({en:'QR ready · expires {expires} · {count} older QR revoked. Download it before leaving this page.','zh-CN':'二维码已就绪 · {expires} 到期 · 已撤销 {count} 个旧二维码。请在离开此页面前下载。',ms:'QR sedia · tamat tempoh {expires} · {count} QR lama dibatalkan. Muat turun sebelum meninggalkan halaman ini.'}),
  qrReadyExpiresQrsRevoked:Object.freeze({en:'QR ready · expires {expires} · {count} older QRs revoked. Download it before leaving this page.','zh-CN':'二维码已就绪 · {expires} 到期 · 已撤销 {count} 个旧二维码。请在离开此页面前下载。',ms:'QR sedia · tamat tempoh {expires} · {count} QR lama dibatalkan. Muat turun sebelum meninggalkan halaman ini.'}),
  activeQrRevoked:Object.freeze({en:'{count} active QR revoked.','zh-CN':'已撤销 {count} 个有效二维码。',ms:'{count} QR aktif dibatalkan.'}),
  activeQrsRevoked:Object.freeze({en:'{count} active QRs revoked.','zh-CN':'已撤销 {count} 个有效二维码。',ms:'{count} QR aktif dibatalkan.'}),
  activeQrExists:Object.freeze({en:'An active QR already exists. Use your saved or printed copy. Replace it only if that copy is lost.','zh-CN':'已有有效二维码。请使用已保存或打印的副本；仅在副本遗失时更换。',ms:'QR aktif sudah wujud. Gunakan salinan yang disimpan atau dicetak. Gantikannya hanya jika salinan itu hilang.'}),
  activeQrExistsUntil:Object.freeze({en:'An active QR already exists until {expires}. Use your saved or printed copy. Replace it only if that copy is lost.','zh-CN':'已有有效二维码，有效期至 {expires}。请使用已保存或打印的副本；仅在副本遗失时更换。',ms:'QR aktif sudah wujud sehingga {expires}. Gunakan salinan yang disimpan atau dicetak. Gantikannya hanya jika salinan itu hilang.'}),
  wizardStepWho:Object.freeze({en:'Step {step} of {total} — Who','zh-CN':'第 {step} 步，共 {total} 步——对象',ms:'Langkah {step} daripada {total} — Sasaran'}),
  wizardStepReward:Object.freeze({en:'Step {step} of {total} — Reward','zh-CN':'第 {step} 步，共 {total} 步——奖励',ms:'Langkah {step} daripada {total} — Ganjaran'}),
  wizardStepSafety:Object.freeze({en:'Step {step} of {total} — Safety','zh-CN':'第 {step} 步，共 {total} 步——安全设置',ms:'Langkah {step} daripada {total} — Keselamatan'}),
  wizardStepReview:Object.freeze({en:'Step {step} of {total} — Review','zh-CN':'第 {step} 步，共 {total} 步——审核',ms:'Langkah {step} daripada {total} — Semakan'}),
  availableStaff:Object.freeze({en:'{staff} is the fairest available choice now. Showing {count} eligible staff member.','zh-CN':'{staff} 是目前最公平的可用选择。显示 {count} 位符合条件的员工。',ms:'{staff} ialah pilihan tersedia yang paling adil sekarang. Menunjukkan {count} kakitangan yang layak.'}),
  availableStaffMany:Object.freeze({en:'{staff} is the fairest available choice now. Showing {count} eligible staff members.','zh-CN':'{staff} 是目前最公平的可用选择。显示 {count} 位符合条件的员工。',ms:'{staff} ialah pilihan tersedia yang paling adil sekarang. Menunjukkan {count} kakitangan yang layak.'}),
  /* V217. Owner: "i selected kelvin - why it show devi next best time?" — the panel always led
     with the FAIREST person, so choosing Kelvin and being told about Devi read as the system
     overruling the choice. It now answers the question actually asked ("is the person I picked
     free?") and offers the fairer option as a suggestion, not a verdict. */
  /* V225: the top bar no longer prints the business name, so the account button needs an
     accessible name of its own. Interpolated attribute copy must be a reviewed template. */
  accountMenuForBusiness:Object.freeze({en:'Account menu for {business}','zh-CN':'{business} 的账户菜单',ms:'Menu akaun untuk {business}'}),
  selectedStaffFree:Object.freeze({en:'{staff} is free at this time.','zh-CN':'{staff} 在这个时间有空。',ms:'{staff} lapang pada masa ini.'}),
  selectedStaffFreeFairer:Object.freeze({en:'{staff} is free at this time. {alt} has had fewer appointments if you would rather spread the work.','zh-CN':'{staff} 在这个时间有空。若想更平均分配，{alt} 的预约较少。',ms:'{staff} lapang pada masa ini. {alt} kurang temu janji jika anda mahu agihkan kerja.'}),
  /* Owner: "recent appointment - how recent?" — the number now states its own window. */
  recentInWindow:Object.freeze({en:'{count} in last {window}','zh-CN':'过去{window}内 {count} 个',ms:'{count} dalam {window} lalu'}),
  /* V267: the id is gone from these two. A staff member reading the session-correction table
     cannot do anything with a UUID, and the owner asked "what is this?" the first time they
     met one. The relationship is what matters and the counterpart row is in the same table. */
  reversalOf:Object.freeze({en:'Reversal of an earlier session use','zh-CN':'冲销较早的次数使用','ms':'Pembalikan penggunaan sesi terdahulu'}),
  usedSessionReversedBy:Object.freeze({en:'Used session → later reversed','zh-CN':'已用次数 → 之后已冲销','ms':'Sesi digunakan → dibalikkan kemudian'}),
  preparingExport:Object.freeze({en:'Preparing {current} of {total}…','zh-CN':'正在准备第 {current}／{total} 条…',ms:'Menyediakan {current} daripada {total}…'}),
  imageCleanupPending:Object.freeze({en:'{count} previous image cleanup item is still pending and will retry.','zh-CN':'仍有 {count} 个先前的图片清理项目待处理，系统将重试。',ms:'{count} tugas pembersihan imej terdahulu masih belum selesai dan akan dicuba semula.'}),
  imageCleanupsPending:Object.freeze({en:'{count} previous image cleanup items are still pending and will retry.','zh-CN':'仍有 {count} 个先前的图片清理项目待处理，系统将重试。',ms:'{count} tugas pembersihan imej terdahulu masih belum selesai dan akan dicuba semula.'}),
  positiveStampCost:Object.freeze({en:'Enter a positive stamps cost','zh-CN':'请输入大于零的印章成本',ms:'Masukkan kos cop yang positif'}),
  positivePointsCost:Object.freeze({en:'Enter a positive points cost','zh-CN':'请输入大于零的积分成本',ms:'Masukkan kos mata yang positif'}),
  switchOtherWorkspace:Object.freeze({en:'Switch to {count} other workspace','zh-CN':'切换到另外 {count} 个工作区',ms:'Tukar kepada {count} ruang kerja lain'}),
  switchOtherWorkspaces:Object.freeze({en:'Switch to {count} other workspaces','zh-CN':'切换到另外 {count} 个工作区',ms:'Tukar kepada {count} ruang kerja lain'}),
  notificationsUnread:Object.freeze({en:'Notifications, {count} unread','zh-CN':'通知，{count} 条未读',ms:'Pemberitahuan, {count} belum dibaca'}),
  phoneKeyDelete:Object.freeze({en:'Delete one digit','zh-CN':'删除一位数字',ms:'Padam satu digit'}),
  phoneKeyClear:Object.freeze({en:'Clear phone number','zh-CN':'清除手机号码',ms:'Kosongkan nombor telefon'}),
  phoneKeyDigit:Object.freeze({en:'Digit {digit}','zh-CN':'数字 {digit}',ms:'Digit {digit}'}),
  openCustomer:Object.freeze({en:'Open customer {name}','zh-CN':'打开顾客 {name}',ms:'Buka pelanggan {name}'}),
  removeItem:Object.freeze({en:'Remove {item}','zh-CN':'移除 {item}',ms:'Alih keluar {item}'}),
  adjustLoyalty:Object.freeze({en:'+/- {unit}','zh-CN':'增加／减少{unit}',ms:'Tambah/tolak {unit}'}),
  viewAppointmentDetails:Object.freeze({en:'View details for {customer}','zh-CN':'查看 {customer} 的预约详情',ms:'Lihat butiran janji temu untuk {customer}'}),
  amendAppointment:Object.freeze({en:'Amend appointment for {customer}','zh-CN':'修改 {customer} 的预约',ms:'Pinda janji temu untuk {customer}'}),
  viewAppointmentAgenda:Object.freeze({en:'View {service} for {customer}, {day}, {time}, {duration} minutes','zh-CN':'查看 {customer} 的 {service}：{day}，{time}，{duration} 分钟',ms:'Lihat {service} untuk {customer}, {day}, {time}, {duration} minit'}),
  calendarAppointment:Object.freeze({en:'{service} for {customer}, {time}, {duration} minutes, {staff}','zh-CN':'{customer} 的 {service}，{time}，{duration} 分钟，{staff}',ms:'{service} untuk {customer}, {time}, {duration} minit, {staff}'}),
  bookAppointmentSlot:Object.freeze({en:'Book {service} with {staff} at {time}','zh-CN':'预约 {service}：{staff}，{time}',ms:'Tempah {service} dengan {staff} pada {time}'}),
  callBookingCustomer:Object.freeze({en:'Call {customer} on {phone}','zh-CN':'致电 {customer}：{phone}',ms:'Hubungi {customer} di {phone}'}),
  removeFromWaitlist:Object.freeze({en:'Remove {customer} from waitlist','zh-CN':'将 {customer} 从候补名单中移除',ms:'Alih keluar {customer} daripada senarai menunggu'}),
  joinedAt:Object.freeze({en:'Joined {date} SGT','zh-CN':'加入时间：{date}（新加坡时间）',ms:'Menyertai pada {date} SGT'}),
  viewDashboardMetricDetails:Object.freeze({en:'View details for {metric}','zh-CN':'查看 {metric} 的详细信息',ms:'Lihat butiran untuk {metric}'}),
  growPublishedReward:Object.freeze({en:'{count} published reward ready for customers.','zh-CN':'已有 {count} 项已发布奖励可供顾客使用。',ms:'{count} ganjaran diterbitkan sedia untuk pelanggan.'}),
  growPublishedRewards:Object.freeze({en:'{count} published rewards ready for customers.','zh-CN':'已有 {count} 项已发布奖励可供顾客使用。',ms:'{count} ganjaran diterbitkan sedia untuk pelanggan.'}),
  growPublishedBringBackRule:Object.freeze({en:'{count} published bring-back rule measuring return visits.','zh-CN':'已有 {count} 条已发布回流规则正在衡量回访。',ms:'{count} peraturan pelanggan kembali yang diterbitkan sedang mengukur lawatan kembali.'}),
  growPublishedBringBackRules:Object.freeze({en:'{count} published bring-back rules measuring return visits.','zh-CN':'已有 {count} 条已发布回流规则正在衡量回访。',ms:'{count} peraturan pelanggan kembali yang diterbitkan sedang mengukur lawatan kembali.'}),
  growDraftReady:Object.freeze({en:'Recommendation draft is ready. Edit any setting; nothing changes for customers until publication.','zh-CN':'推荐草稿已就绪。您可编辑任何设置；发布前不会改变顾客体验。',ms:'Draf cadangan sedia. Edit mana-mana tetapan; tiada perubahan untuk pelanggan sehingga diterbitkan.'}),
  publishImpactAction:Object.freeze({en:'{live} action starts running now · {shadow} shadow-test only · {unbuilt} stay off (not built yet)','zh-CN':'{live} 个操作立即运行 · {shadow} 个仅进行影子测试 · {unbuilt} 个保持关闭（尚未构建）',ms:'{live} tindakan mula berjalan sekarang · {shadow} ujian bayangan sahaja · {unbuilt} kekal dimatikan (belum dibina)'}),
  publishImpactActions:Object.freeze({en:'{live} actions start running now · {shadow} shadow-test only · {unbuilt} stay off (not built yet)','zh-CN':'{live} 个操作立即运行 · {shadow} 个仅进行影子测试 · {unbuilt} 个保持关闭（尚未构建）',ms:'{live} tindakan mula berjalan sekarang · {shadow} ujian bayangan sahaja · {unbuilt} kekal dimatikan (belum dibina)'}),
  publishMoneyLive:Object.freeze({en:'Money at checkout: a live rule will change totals now','zh-CN':'结账金额：一条实时规则将立即更改总额',ms:'Wang semasa pembayaran: peraturan langsung akan mengubah jumlah sekarang'}),
  publishMoneyNone:Object.freeze({en:'Money at checkout: no live money change from this publish','zh-CN':'结账金额：此次发布不会立即更改金额',ms:'Wang semasa pembayaran: tiada perubahan wang langsung daripada penerbitan ini'}),
  publishCustomersLive:Object.freeze({en:'Customers: can see or receive something as soon as you publish','zh-CN':'顾客：发布后可立即看到或收到内容',ms:'Pelanggan: boleh melihat atau menerima sesuatu sebaik sahaja anda menerbitkan'}),
  publishCustomersNone:Object.freeze({en:'Customers: nothing new reaches customers from this publish','zh-CN':'顾客：此次发布不会向顾客发送任何新内容',ms:'Pelanggan: tiada perkara baharu sampai kepada pelanggan daripada penerbitan ini'}),
  publishDraftVersion:Object.freeze({en:'Exactly what happens when you publish draft v{version}.','zh-CN':'发布草稿 v{version} 时将发生的确切变化。',ms:'Perkara tepat yang berlaku apabila anda menerbitkan draf v{version}.'}),
  publishConfirmationSensitive:Object.freeze({en:'This turns on a live rule that affects money or customers. Type PUBLISH below to confirm you reviewed the impact.','zh-CN':'这将启用影响金额或顾客的实时规则。请在下方输入 PUBLISH，确认您已审核影响。',ms:'Ini menghidupkan peraturan langsung yang mempengaruhi wang atau pelanggan. Taip PUBLISH di bawah untuk mengesahkan anda telah menyemak kesannya.'}),
  publishConfirmationStandard:Object.freeze({en:'Review complete. Type PUBLISH below to confirm this exact draft.','zh-CN':'审核完成。请在下方输入 PUBLISH，以确认这份确切草稿。',ms:'Semakan selesai. Taip PUBLISH di bawah untuk mengesahkan draf tepat ini.'}),
  classicEligibleEarning:Object.freeze({en:'Eligible customer-linked sales earn points when this programme is active, published, and available at the selected branch. At {points} points, one tap converts them into {credit} of real in-store credit. Switch models above any time — balances carry over.','zh-CN':'当此方案生效、已发布且在所选分店可用时，合资格且关联顾客的销售可赚取积分。达到 {points} 积分后，只需轻点一下即可转换为 {credit} 的实际店内余额。您可随时切换上方模式，余额会保留。',ms:'Jualan layak yang dipautkan kepada pelanggan memperoleh mata apabila program ini aktif, diterbitkan dan tersedia di cawangan yang dipilih. Pada {points} mata, satu ketikan menukarkannya kepada kredit dalam kedai sebenar sebanyak {credit}. Tukar model di atas pada bila-bila masa — baki kekal.'}),
  stampsEligibleEarning:Object.freeze({en:'Eligible customer-linked sales add stamps when this programme is active, published, and available at the selected branch. Define what each milestone is worth — a free item to hand over, or store credit.','zh-CN':'当此方案生效、已发布且在所选分店可用时，合资格且关联顾客的销售会增加印花。请定义每个里程碑的价值，例如可交付的免费商品或店内余额。',ms:'Jualan layak yang dipautkan kepada pelanggan menambah cop apabila program ini aktif, diterbitkan dan tersedia di cawangan yang dipilih. Tetapkan nilai setiap pencapaian — item percuma untuk diserahkan atau kredit kedai.'}),
  referralEnabledOutcome:Object.freeze({en:'When the programme is Enabled, the new customer’s first sale above the minimum can add {amount} to the referrer’s account — audited, once only.','zh-CN':'当计划已启用时，新顾客首次达到最低消费的销售可向推荐人账户加入 {amount}；全程审计且仅发放一次。',ms:'Apabila program Dihidupkan, jualan pertama pelanggan baharu yang melebihi minimum boleh menambah {amount} ke akaun perujuk — diaudit, sekali sahaja.'})
});
const WORKSPACE_INTERPOLATED_UI_INVENTORY_V97=Object.freeze([
  'customerPagination','completedTransaction','completedTransactions',
  'scopePeriod','allBranchesPeriod','scopeCustomers','customerRecordExported',
  'customerRecordsExported','customersShown','importBooking','importBookings',
  'bookingsReady','firstBookings','importBookingPreview','firstImportError','firstImportErrors',
  'importedBooking','importedBookings','importCustomers',
  'customersReady','firstCustomers','requestStatus','adjustedBalance','itemAdded','itemSelected',
  'noValidImportRows','noValidImportRowsSkipped','importRowsReady','importRowsReadySkipped',
  'bookedWith','newReturn','newReturns','measurementStarted','measurementStartedEnds',
  'receiptConfirmationRecorded','receiptConfirmationsRecorded',
  'receiptConfirmationFailed','receiptConfirmationsFailed',
  'exposureRetryChannelLocked','exposureRetryMixedChannels',
  'packageVersionCreated',
  'giftCardLoaded','sessionUsed','welcomeOfferGiven',
  'catalogueEnabled','catalogueDisabled','inviteCreated','importPartial',
  'customersImported','customersImportPreview','packageHistory','packageHistoryWithOlder',
  'appointmentChanged','appointmentStatus','exactSnapshotMismatch','qrReady',
  'qrReadyExpires','qrReadyRevoked','qrReadyQrsRevoked','qrReadyExpiresRevoked',
  'qrReadyExpiresQrsRevoked','activeQrRevoked',
  'activeQrsRevoked','activeQrExists','activeQrExistsUntil',
  'wizardStepWho','wizardStepReward','wizardStepSafety','wizardStepReview',
  'availableStaff','availableStaffMany','reversalOf',
  'selectedStaffFree','selectedStaffFreeFairer','recentInWindow','accountMenuForBusiness',
  'performancePeriodRange','pointCostDerived','parkExpiryPreview','parkExpiryPreviewTier','parkKeptUntil',
  'sortByAscending','sortByDescending','bottlePercentLeft',
  'bookingRequestWaiting','bookingRequestsWaitingMany','bookingRequestsBadge',
  'staffKeptHasRecord','staffKeptHasRecords',
  'usedSessionReversedBy','preparingExport','imageCleanupPending','imageCleanupsPending',
  'positiveStampCost','positivePointsCost','switchOtherWorkspace','switchOtherWorkspaces',
  'notificationsUnread','phoneKeyDelete','phoneKeyClear','phoneKeyDigit','openCustomer',
  'removeItem','adjustLoyalty','viewAppointmentDetails','amendAppointment',
  'viewAppointmentAgenda','calendarAppointment','callBookingCustomer','bookAppointmentSlot','removeFromWaitlist','joinedAt',
  'viewDashboardMetricDetails',
  'growPublishedReward','growPublishedRewards','growPublishedBringBackRule',
  'growPublishedBringBackRules','growDraftReady','publishImpactAction',
  'publishImpactActions','publishMoneyLive','publishMoneyNone',
  'publishCustomersLive','publishCustomersNone','publishDraftVersion',
  'publishConfirmationSensitive','publishConfirmationStandard',
  'classicEligibleEarning','stampsEligibleEarning','referralEnabledOutcome'
]);
const WORKSPACE_INTERPOLATED_ATTRIBUTE_INVENTORY_V97=Object.freeze([
  'switchOtherWorkspace','switchOtherWorkspaces','notificationsUnread',
  'phoneKeyDelete','phoneKeyClear','phoneKeyDigit','openCustomer','removeItem',
  'adjustLoyalty','viewAppointmentDetails','amendAppointment','viewAppointmentAgenda',
  'calendarAppointment','bookAppointmentSlot','removeFromWaitlist','joinedAt','viewDashboardMetricDetails'
]);
const workspaceTemplateTextV97=(key,values={},locale=workspaceLocale)=>{
  const copy=WORKSPACE_TEMPLATE_COPY_V97[key],template=copy?.[locale]??copy?.en??'';
  return template.replace(/\{([a-z][a-z0-9_]*)\}/gi,(_,name)=>String(values[name]??''));
};
const WORKSPACE_TEMPLATE_ATTRIBUTES_V97=Object.freeze(['aria-label','title','placeholder']);
const workspaceTemplateAttributeV97=(attribute,key,values={})=>{
  if(!WORKSPACE_TEMPLATE_ATTRIBUTES_V97.includes(attribute)
     ||!WORKSPACE_INTERPOLATED_ATTRIBUTE_INVENTORY_V97.includes(key))return '';
  const encoded=encodeURIComponent(JSON.stringify(values));
  return `data-workspace-${attribute}-template="${esc(key)}" data-workspace-${attribute}-values="${esc(encoded)}" ${attribute}="${esc(workspaceTemplateTextV97(key,values))}"`;
};
const workspaceTemplateInnerHtmlV97=(key,values={},locale=workspaceLocale)=>{
  const copy=WORKSPACE_TEMPLATE_COPY_V97[key],template=copy?.[locale]??copy?.en??'';
  let cursor=0,html='';
  for(const match of template.matchAll(/\{([a-z][a-z0-9_]*)\}/gi)){
    html+=esc(template.slice(cursor,match.index));
    const name=match[1];
    html+=`<span data-workspace-value="${esc(name)}" data-merchant-content>${esc(values[name]??'')}</span>`;
    cursor=match.index+match[0].length;
  }
  return html+esc(template.slice(cursor));
};
const workspaceTemplateHtmlV97=(key,values={})=>`<span data-workspace-template="${esc(key)}">${workspaceTemplateInnerHtmlV97(key,values)}</span>`;
/* ---------- customers ---------- */
function normalizeSingaporeCustomerSearch(value){
  let digits=String(value||'').replace(/\D/g,'');
  if(digits.length===10&&digits.startsWith('65'))digits=digits.slice(2);
  return digits.length===8?digits:null;
}
/* V200 (owner: "in all the modules i need you to simplify the sub modules ... just tab the sub
   modules and can view easily instead of long scrolling"). ONE mechanism for every module,
   matching the Bookings pill strip the owner pointed at.

   A page opts in declaratively: tag a top-level section with data-subtab="Group". Anything
   UNTAGGED stays pinned above the strip, which is what keeps a module's title, date filters and
   primary action reachable from every tab instead of hiding inside whichever one happens to be
   open. Tabs appear in the order their group is first seen, so the strip is the page's own
   reading order rather than a second list to keep in sync — add a section, it lands in the right
   tab with no wiring.

   The chosen tab is remembered per module, because an owner who lives in one sub-module should
   not re-select it on every visit. It is remembered in sessionStorage, not localStorage: a tab is
   a "where was I just now", and restoring last week's choice would hide the section they came
   for. Fewer than two groups means no strip at all — a one-section page keeps scrolling. */
function revealSectionTabV200(node){
  const panel=node?.closest?.('[data-subtab-panel]');
  if(!panel||!panel.hidden)return false;
  const tab=panel.getRootNode()?.getElementById?.(panel.getAttribute('aria-labelledby'))
    ||document.getElementById(panel.getAttribute('aria-labelledby'));
  if(!tab)return false;
  tab.click();
  return true;
}
function promotionDateTextV104(value){
  if(!value)return '';
  const instant=/^\d{4}-\d{2}-\d{2}$/.test(String(value))
    ?new Date(`${value}T12:00:00+08:00`):new Date(value);
  return new Intl.DateTimeFormat('en-SG',{timeZone:'Asia/Singapore',day:'numeric',month:'long',year:'numeric'}).format(instant);
}
/* ----- validator error-code -> human message ----- */
const STUDIO_ERRMAP={
  rule_not_object:'The rule is empty.',unsupported_rule_field:'The rule has a field we do not support.',
  invalid_schema_version:'This rule uses an unsupported version.',invalid_event:'Choose when this rule should run.',
  if_not_array:'The conditions are malformed.',too_many_conditions:'Too many conditions (up to 10).',
  then_not_array:'The actions are malformed.',too_many_effects:'Too many actions (up to 8).',
  condition_not_object:'A condition is malformed.',condition_unsupported_key:'A condition has an unsupported field.',
  in_requires_array:'Choose one or more values for this condition.',between_requires_pair:'Enter both a low and a high value.',
  effect_not_object:'An action is malformed.',effect_unsupported_key:'An action has an unsupported field.',
  client_supplied_price:'Prices come from your catalog, not from the rule.',sql_fragment_forbidden:'That value is not allowed.',
  effect_amount_required:'Enter an amount greater than zero.',effect_discount_pct_range:'Enter a discount between 0 and 100%.',
  effect_points_required:'Enter a points amount greater than zero.',effect_stamps_required:'Enter a stamps amount greater than zero.',
  effect_multiplier_range:'The multiplier must be at least 1.',effect_catalog_ref_not_found:'Choose a valid item for the free-item action.',
  schedule_not_object:'The schedule is malformed.',schedule_unsupported_key:'The schedule has an unsupported setting.',
  schedule_non_sgt:'The schedule must use Singapore time.',schedule_end_before_start:'The end date is before the start date.',
  schedule_bad_date:'Check the schedule dates.',schedule_dow_not_array:'Choose valid days of the week.',
  schedule_dow_range:'Choose valid days of the week.',schedule_bad_time:'Check the schedule times.',
  stacking_not_object:'The stacking settings are malformed.',stacking_unsupported_key:'The stacking settings have an unsupported option.',
  stacking_stackable_type:'The "can combine" setting is invalid.',stacking_max_stack_range:'The maximum stack must be at least 1.',
  stacking_bad_number:'Check the stacking numbers.'
};
function studioErrText(code){
  const parts=String(code||'').split(':');const base=parts[0],arg=parts[1];
  if(base==='unknown_condition_field')return `"${esc(arg||'')}" is not a valid condition for this event.`;
  if(base==='invalid_operator')return `"${esc(arg||'')}" is not a valid comparison.`;
  if(base==='invalid_effect')return `"${esc(arg||'')}" is not a valid action for this event.`;
  if(base==='catalog_ref_not_found')return `A selected ${esc(arg||'item')} could not be found.`;
  return STUDIO_ERRMAP[base]||esc(code);
}

async function loadStudioSalesAgg(guard){
  const {data,error}=await sb.rpc('get_studio_sales_baseline_v145',{p_business:S.biz.id});
  if(guard&&!guard())return null;
  return {count30:error?null:Number(data?.count30||0),avgBill:Number(data?.avg_bill_cents||0),ok:!error};
}

/* ---------------- Draft editor: Quick Start + Guided + Advanced, live-validated ---------------- */
let studioEd=null;  // in-flight working rule for the open editor (null = editor closed)

/* ============================ Stored value (PS-2A Increment D) ============================
   The FIRST owner-only stored-value surface. Truthfulness is the whole point (STORED_VALUE_CONTRACT
   §10 + INCREMENT_D_CONTRACT §4):
   - authority_state and reconciliation status are rendered VERBATIM from the server; the browser
     NEVER infers, computes or upgrades them.
   - stored value is NEVER presented as usable while authority != 'live' — and 'live' is unreachable
     in PS-2A, so the state is always unbuilt / shadow_testing / reconciliation_blocked / paused.
     There is NO customer spend/top-up/grant UI here; nothing moves real value.
   - reconciliation discrepancies are SHOWN, never hidden, with categories in plain words + cents.
   - every dangerous action (run reconciliation, change authority, pause, lift) is explicitly
     confirmed; the server requires a reason (>=3 chars) where noted.
   - it FAILS CLOSED: if get_sv_authority_overview OR get_sv_reconciliation errors, an error state
     renders and NO control is drawn — nothing is ever assumed live/clean/usable.
   RPCs consumed: get_sv_authority_overview, get_sv_reconciliation, preview_sv_cutover (reads);
   set_sv_authority_state, sv_pause, sv_lift_pause, run_sv_reconciliation, sv_cutover_business
   (owner-only writes). v69: 'live' IS reachable now, for one super-admin-designated business, via
   sv_cutover_business - so the copy on this screen is state-driven rather than asserting that
   nothing is ever live. preview_sv_cutover.ready is a server computation; the browser renders it. */
const SV_ASSET='stored_value';
const SV_SCOPE_WORDS={all:'everything',earn:'top-ups & grants',redeem:'spending'};
const SV_AUTHORITY_WORDS={
  unbuilt:'Not built for this business yet — nothing is live.',
  shadow_testing:'Shadow testing only — simulated. No customer can use this value.',
  reconciliation_blocked:'Blocked by a reconciliation difference — not usable until it is cleared.',
  ready_for_cutover:'Reconciled, awaiting a future authorized cutover — not usable yet.',
  live:'Live.',
  paused:'Paused — no customer can use this value right now.',
  retired:'Retired — superseded; history is preserved.'
};
/* Plain-language names for the six reconciliation discrepancy categories (contract §7). The raw
   category is also shown verbatim beside the plain words — nothing is invented or hidden. */
const SV_DISCREPANCY_WORDS={
  missing_in_studio:'in gift cards, not yet in stored value',
  missing_in_legacy:'in stored value, not in gift cards',
  amount_mismatch:'amounts differ',
  invalid_legacy_balance:'legacy balance invalid',
  duplicate_legacy_event:'duplicate legacy record',
  orphan_legacy_record:'legacy record inconsistent'
};
const svTime=v=>v?esc(String(v).slice(0,16).replace('T',' '))+' (server time)':'';
/* The chip LABEL is the server's authority_state VERBATIM. The browser never computes or infers
   it — only get_sv_authority_overview.authority_state is shown. Only 'live' is ever an affirmative
   pill, and 'live' is unreachable in PS-2A; an unknown value fails closed to a red pill and is
   still shown as-is. Deliberately a SEPARATE function from studioStateChip/legacyStateChip so the
   truthful-state rule stays grep-provable. */
function svAuthorityChip(state){
  const cls=state==='live'?'on'
    :(state==='shadow_testing'||state==='ready_for_cutover')?'new'
    :state==='reconciliation_blocked'?'no'
    :['unbuilt','paused','retired'].includes(state)?'off':'no';
  return `<span class="pill ${cls}">${esc(state==null?'unknown':String(state))}</span>`;
}
/* Reconciliation status rendered verbatim: clean/blocked from the latest snapshot, else not-run. */
function svReconStatusChip(status,hasRun){
  if(!hasRun)return `<span class="pill off">not run yet</span>`;
  const cls=status==='clean'?'ok':status==='blocked'?'no':'off';
  return `<span class="pill ${cls}">${esc(status==null?'unknown':String(status))}</span>`;
}
/* Shared confirm-with-reason modal for the stored-value owner actions. Every dangerous action is
   explicit: the owner must confirm, and — where reasonLabel is set — type a reason (>=3 chars, to
   match sv_apply_authority_state / sv_pause). onSubmit({reason}) performs exactly one RPC and
   returns its {error}; a 42501 surfaces as an owner-only message. String-literal RPC names are used
   at the call sites (not a variable) so writer-discovery audits SEE each writer surface. */
function svOpenActionModal({title,intro,reasonLabel,reasonPlaceholder='',submitLabel,danger=false,onSubmit,onDone}){
  document.body.insertAdjacentHTML('beforeend',`<div class="modal" id="svActionModal" role="dialog" aria-modal="true" aria-labelledby="svActionTitle" tabindex="-1"><div class="modal-card" style="max-width:520px">
    <div class="row"><div><h2 id="svActionTitle">${esc(title)}</h2><p class="muted small">${esc(intro)}</p></div><span class="spacer"></span><button class="btn ghost sm" id="svActionClose" type="button">Close</button></div>
    ${reasonLabel?`<label for="svActionReason">${esc(reasonLabel)}</label><textarea id="svActionReason" rows="3" data-workspace-i18n placeholder="${esc(reasonPlaceholder)}"></textarea>`:''}
    <div id="svActionErr"></div>
    <div class="row" style="margin-top:16px"><button class="btn ${danger?'danger':''}" id="svActionSubmit" type="button">${esc(submitLabel)}</button><button class="btn ghost sm" id="svActionCancel" type="button">Cancel</button></div>
  </div></div>`);
  let deactivate;
  const close=()=>{if(deactivate)deactivate();else $('svActionModal')?.remove();};
  deactivate=CUI.activateDialog($('svActionModal'),{onClose:close,initialFocus:reasonLabel?'#svActionReason':'#svActionSubmit'});
  $('svActionClose').onclick=$('svActionCancel').onclick=close;
  $('svActionSubmit').onclick=async()=>{
    let reason=null;
    if(reasonLabel){
      reason=($('svActionReason').value||'').trim();
      if(reason.length<3){$('svActionErr').innerHTML='<div class="err">Write a short reason (at least 3 characters).</div>';return;}
    }
    const btn=$('svActionSubmit');btn.disabled=true;btn.setAttribute('aria-busy','true');
    let res;
    try{res=await onSubmit({reason});}
    catch(e){res={error:{message:e&&e.message||String(e)}};}
    btn.removeAttribute('aria-busy');
    const error=res&&res.error;
    if(error){
      btn.disabled=false;
      if(error.code==='42501'){$('svActionErr').innerHTML='<div class="err">Only the owner can do this.</div>';return;}
      $('svActionErr').innerHTML=`<div class="err">${esc(error.message||'Could not complete this. Try again.')}</div>`;return;
    }
    close();
    if(onDone)onDone();
  };
}

/* ============================ Stored value — staff-assisted top-up sale (v66) ============================
   A fully SERVER-AUTHORITATIVE inline wizard rendered into #svTopupFlow. The client NEVER computes a
   price, bonus, expiry, discount or balance: it identifies the customer (lookup_client_by_phone), lists
   sellable plans (get_sellable_sv_topup_plans), shows a server preview (preview_sv_topup_sale), and, only
   on explicit confirmation, records the sale (record_sv_topup_sale) with a single idempotency key. It
   surfaces every server blocker/refusal verbatim and never says value is "available to spend" unless the
   server's own `spendable` flag is true (only ever in `live`). In shadow_testing/ready_for_cutover the
   only offered method is `test` and the copy states plainly that nothing real is collected or spendable. */
async function svRunTopupFlow({branches,state,testOnly}){
  const host=$('svTopupFlow'); if(!host)return;
  const methodOpts=testOnly
    ? [['test','Test (no real money)']]
    : [['cash','Cash'],['card_terminal','Card terminal'],['paynow','PayNow'],['manual','Manual']];
  const st={step:'customer',branchId:(branches[0]&&branches[0].id)||null,phone:'',cust:null,plans:[],
    versionId:null,method:methodOpts[0][0],reference:'',staffConfirmed:false,preview:null,idemKey:null,
    result:null,busy:false,err:null};
  const alive=()=>host.isConnected&&$('svTopupFlow')===host;
  const selPlan=()=>st.plans.find(p=>p&&p.version_id===st.versionId)||null;
  const needsReference=()=>['card_terminal','paynow','manual'].includes(st.method);
  const paymentObj=p=>{ // p = the plan projection whose amount/currency we must match exactly
    const o={method:st.method,amount_cents:p?Number(p.price_cents):0,currency:(p&&p.currency)||S.biz.currency||'SGD'};
    const ref=st.reference.trim(); if(ref)o.reference=ref;
    o.staff_confirmed=needsReference()?!!st.staffConfirmed:true;
    return o;
  };

  async function loadPlans(){
    st.busy=true;st.err=null;render();
    const {data,error}=await sb.rpc('get_sellable_sv_topup_plans',{p_business:S.biz.id,p_branch:st.branchId,p_client:st.cust.client_id});
    if(!alive())return; st.busy=false;
    if(error){st.err=error.message||'Plans could not be loaded.';render();return;}
    st.plans=(data&&Array.isArray(data.plans))?data.plans:[];
    const firstOk=st.plans.find(p=>p&&p.ok); st.versionId=firstOk?firstOk.version_id:(st.plans[0]&&st.plans[0].version_id)||null;
    st.step='plan';render();
  }
  async function findCustomer(){
    const phone=(($('svtPhone')||{}).value||'').trim();
    if(!phone){st.err='Enter the customer mobile number.';render();return;}
    st.phone=phone;st.busy=true;st.err=null;render();
    const {data,error}=await sb.rpc('lookup_client_by_phone',{p_business:S.biz.id,p_phone:phone});
    if(!alive())return; st.busy=false;
    if(error){st.err=error.message||'Lookup failed.';render();return;}
    if(data.status==='found'){st.cust={client_id:data.client_id,full_name:data.full_name,phone:data.phone||phone};loadPlans();return;}
    if(data.status==='not_found'){st.cust=null;st.err='No customer with that number. A top-up needs an existing customer; add them first from Customers or Record sale.';render();return;}
    st.err=(data&&data.message)||'Enter a valid Singapore number.';render();
  }
  async function doPreview(){
    const p=selPlan(); if(!p){st.err='Choose a plan first.';render();return;}
    if(needsReference()&&!st.reference.trim()){st.err='A payment reference is required for this method.';render();return;}
    if(needsReference()&&!st.staffConfirmed){st.err='Tick the confirmation box before previewing this method.';render();return;}
    st.busy=true;st.err=null;render();
    const {data,error}=await sb.rpc('preview_sv_topup_sale',{p_business:S.biz.id,p_branch:st.branchId,p_client:st.cust.client_id,p_plan_version:st.versionId,p_payment:paymentObj(p)});
    if(!alive())return; st.busy=false;
    if(error){st.err=error.message||'Preview failed.';render();return;}
    st.preview=data;st.idemKey=crypto.randomUUID();st.step='confirm';render();
  }
  async function doRecord(){
    const p=selPlan(); if(!p||!st.idemKey)return;
    st.busy=true;st.err=null;render();
    const {data,error}=await sb.rpc('record_sv_topup_sale',{p_business:S.biz.id,p_branch:st.branchId,p_client:st.cust.client_id,p_plan_version:st.versionId,p_payment:paymentObj(p),p_idempotency_key:st.idemKey});
    if(!alive())return; st.busy=false;
    if(error){st.err=error.message||'The top-up could not be recorded.';render();return;}
    if(data&&data.status&&data.status!=='ok'){st.err='The top-up was not completed: '+String(data.reason||data.status)+'.';render();return;}
    st.result=data;st.step='done';render();
  }

  function blockersHtml(list){
    const b=Array.isArray(list)?list:[];
    return b.length?`<div class="muted small" style="margin-top:6px;line-height:1.6"><b>Not sellable right now:</b><ul style="margin:6px 0 0 18px">${b.map(x=>`<li>${esc(String(x))}</li>`).join('')}</ul></div>`:'';
  }
  function expiryWords(days){return days==null?'no expiry':days+' day'+(Number(days)===1?'':'s');}

  function render(){
    if(!alive())return;
    const busyAttr=st.busy?' disabled aria-busy="true"':'';
    const errHtml=st.err?`<div class="err" role="alert" style="margin-top:10px">${esc(st.err)}</div>`:'';
    const branchPicker=branches.length>1?`<div><label for="svtBranch" class="muted small">Branch</label><br><select id="svtBranch" style="max-width:280px">${branches.map(b=>`<option value="${esc(b.id)}"${b.id===st.branchId?' selected':''}>${esc(b.name||'Branch')}</option>`).join('')}</select></div>`:'';
    let body='';
    if(st.step==='customer'){
      body=`<div class="cui-card-head"><h3>Who is this top-up for?</h3></div>
        <div class="row" style="gap:8px;flex-wrap:wrap;align-items:end">
          ${branchPicker}
          <div><label for="svtPhone" class="muted small">Customer mobile</label><br><input id="svtPhone" type="tel" inputmode="tel" autocomplete="off" value="${esc(st.phone)}" placeholder="e.g. 8123 4567" style="max-width:220px"></div>
          <button class="btn sm" id="svtFind" type="button"${busyAttr}>${st.busy?'Finding…':'Find customer'}</button>
        </div>${errHtml}`;
    } else if(st.step==='plan'){
      const p=selPlan();
      const planRadios=st.plans.length?st.plans.map(pl=>{
        const dis=!pl.ok?' disabled':'';
        return `<label class="row" style="gap:10px;align-items:flex-start;padding:10px;border:1px solid var(--line);border-radius:10px;margin-top:8px${pl.ok?'':';opacity:.7'}">
          <input type="radio" name="svtPlan" value="${esc(pl.version_id)}"${pl.version_id===st.versionId?' checked':''}${dis} style="margin-top:4px">
          <div style="flex:1;min-width:0"><div style="font-weight:700">${esc(pl.plan_name||'Plan')}</div>
            <div class="muted small" style="margin-top:2px">Pay <b>${money(Number(pl.price_cents||0))}</b>${Number(pl.bonus_cents||0)>0?` · bonus <b>${money(Number(pl.bonus_cents))}</b>`:''} · total value <b>${money(Number(pl.total_usable_cents||0))}</b></div>
            <div class="muted small">Paid value expiry: ${esc(expiryWords(pl.paid_expiry_days))}${Number(pl.bonus_cents||0)>0?` · bonus expiry: ${esc(expiryWords(pl.bonus_expiry_days))}`:''}</div>
            ${blockersHtml(pl.blockers)}</div></label>`;
      }).join(''):`<p class="muted small" style="margin-top:8px">No sellable plans for this customer at this branch. ${state==='unbuilt'?'Stored value is unbuilt.':'Publish a top-up plan first, or check the plan restrictions.'}</p>`;
      const methodSel=`<div><label for="svtMethod" class="muted small">Payment method</label><br><select id="svtMethod" style="max-width:220px"${testOnly?' disabled':''}>${methodOpts.map(([v,l])=>`<option value="${v}"${v===st.method?' selected':''}>${esc(l)}</option>`).join('')}</select></div>`;
      const refField=needsReference()?`<div><label for="svtRef" class="muted small">Payment reference (required)</label><br><input id="svtRef" type="text" value="${esc(st.reference)}" placeholder="e.g. terminal approval code" style="max-width:260px"></div>`:'';
      const confirmBox=needsReference()?`<label class="row small" style="gap:8px;align-items:flex-start;margin-top:8px"><input type="checkbox" id="svtConfirm"${st.staffConfirmed?' checked':''} style="margin-top:3px"><span>I confirm the customer has paid${p?` ${money(Number(p.price_cents||0))}`:''}. <b>${esc(BRAND.productName)} has not verified this payment</b> — you are attesting it was received.</span></label>`:'';
      body=`<div class="cui-card-head"><h3>${esc(st.cust.full_name||'Customer')} · ${esc(st.cust.phone||'')}</h3><p>Choose the plan and payment. Amounts are set by the plan and cannot be edited here.</p></div>
        ${planRadios}
        <div class="row" style="gap:10px;flex-wrap:wrap;align-items:end;margin-top:14px">${methodSel}${refField}</div>
        ${confirmBox}${errHtml}
        <div class="row" style="gap:8px;margin-top:14px"><button class="btn ghost sm" id="svtBack" type="button">Back</button><button class="btn sm" id="svtPreview" type="button"${(!p||!p.ok)?' disabled aria-disabled="true"':''}${busyAttr}>${st.busy?'Checking…':'Preview'}</button></div>`;
    } else if(st.step==='confirm'){
      const pv=st.preview||{};
      const cash=Number(pv.price_cents||0), bonus=Number(pv.bonus_cents||0), total=Number(pv.total_usable_cents||0);
      const cur=(pv.currency||S.biz.currency||'SGD');
      const blocked=Array.isArray(pv.blockers)&&pv.blockers.length>0;
      const spendable=pv.spendable===true;
      body=`<div class="cui-card-head"><h3>Confirm this top-up</h3></div>
        <aside class="permission-banner" role="note" style="border-color:var(--line)">${CUI.icon('info',{size:19})}<div>
          <b>You are collecting ${esc(cur)} ${(cash/100).toFixed(2)} and issuing ${esc(cur)} ${(cash/100).toFixed(2)} paid value${bonus>0?` plus ${esc(cur)} ${(bonus/100).toFixed(2)} promotional bonus`:''}.</b>
          <p>${spendable?'This value will be spendable by the customer.':'This is a test in this phase — the value is <b>not</b> spendable and no real money is collected.'}</p></div></aside>
        <dl class="cui-readonly-list" style="margin-top:12px">
          <div class="cui-readonly-row"><dt>Customer</dt><dd>${esc(st.cust.full_name||'')} · ${esc(st.cust.phone||'')}</dd></div>
          <div class="cui-readonly-row"><dt>Plan</dt><dd>${esc(pv.plan_name||'')}</dd></div>
          <div class="cui-readonly-row"><dt>Collect</dt><dd><b>${money(cash)}</b> · ${esc((methodOpts.find(m=>m[0]===st.method)||['',st.method])[1])}</dd></div>
          <div class="cui-readonly-row"><dt>Paid value issued</dt><dd>${money(cash)}</dd></div>
          ${bonus>0?`<div class="cui-readonly-row"><dt>Bonus value issued</dt><dd>${money(bonus)}</dd></div>`:''}
          <div class="cui-readonly-row"><dt>Total value</dt><dd><b>${money(total)}</b></dd></div>
          <div class="cui-readonly-row"><dt>Paid value expiry</dt><dd>${esc(expiryWords(pv.paid_expiry_days))}</dd></div>
          ${bonus>0?`<div class="cui-readonly-row"><dt>Bonus value expiry</dt><dd>${esc(expiryWords(pv.bonus_expiry_days))}</dd></div>`:''}
          ${st.reference.trim()?`<div class="cui-readonly-row"><dt>Reference</dt><dd>${esc(st.reference.trim())}</dd></div>`:''}
          <div class="cui-readonly-row"><dt>Projected balance after</dt><dd>${money(Number(pv.projected_account_total_cents||0))}${spendable?'':' (not spendable)'}</dd></div>
        </dl>
        ${blockersHtml(pv.blockers)}${errHtml}
        <div class="row" style="gap:8px;margin-top:14px"><button class="btn ghost sm" id="svtBack" type="button">Back</button><button class="btn sm" id="svtRecord" type="button"${blocked?' disabled aria-disabled="true"':''}${busyAttr}>${st.busy?'Recording…':'Confirm & record'}</button></div>`;
    } else if(st.step==='done'){
      const r=st.result||{};
      const spendable=r.spendable===true;
      body=`<div class="cui-card-head"><h3>Top-up recorded</h3></div>
        <div class="ok" role="status" style="margin-top:6px"><b>Done.</b> ${spendable?'The value is now available to the customer.':'This was a test — the value is recorded but is <b>not</b> available to spend.'}</div>
        <dl class="cui-readonly-list" style="margin-top:12px">
          <div class="cui-readonly-row"><dt>Cash collected</dt><dd>${money(Number(r.cash_collected_cents||0))}</dd></div>
          <div class="cui-readonly-row"><dt>Paid value issued</dt><dd>${money(Number(r.paid_value_issued_cents||0))}</dd></div>
          ${Number(r.bonus_value_issued_cents||0)>0?`<div class="cui-readonly-row"><dt>Bonus value issued</dt><dd>${money(Number(r.bonus_value_issued_cents))}</dd></div>`:''}
          <div class="cui-readonly-row"><dt>Total account value</dt><dd><b>${money(Number(r.account_total_after_cents||0))}</b>${spendable?'':' (not spendable)'}</dd></div>
          <div class="cui-readonly-row"><dt>Spendable</dt><dd>${spendable?'Yes':'No — '+esc(String(r.authority_state||state))}</dd></div>
          ${r.operation_id?`<div class="cui-readonly-row"><dt>Reference</dt><dd><code>${esc(String(r.operation_id))}</code></dd></div>`:''}
        </dl>
        <div class="row" style="gap:8px;margin-top:14px"><button class="btn sm" id="svtAgain" type="button">Record another</button></div>`;
    }
    host.innerHTML=`<div class="card" style="border-color:var(--line)">${body}</div>`;
    if($('svtBranch'))$('svtBranch').onchange=e=>{st.branchId=e.target.value;};
    if($('svtFind'))$('svtFind').onclick=findCustomer;
    if($('svtPhone'))$('svtPhone').onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();findCustomer();}};
    host.querySelectorAll('input[name="svtPlan"]').forEach(r=>r.onchange=()=>{st.versionId=r.value;st.err=null;render();});
    if($('svtMethod'))$('svtMethod').onchange=e=>{st.method=e.target.value;st.err=null;render();};
    if($('svtRef'))$('svtRef').oninput=e=>{st.reference=e.target.value;};
    if($('svtConfirm'))$('svtConfirm').onchange=e=>{st.staffConfirmed=e.target.checked;};
    if($('svtPreview'))$('svtPreview').onclick=doPreview;
    if($('svtRecord'))$('svtRecord').onclick=doRecord;
    if($('svtBack'))$('svtBack').onclick=()=>{st.err=null;st.step=(st.step==='confirm')?'plan':'customer';if(st.step==='customer'){st.plans=[];}render();};
    if($('svtAgain'))$('svtAgain').onclick=()=>{st.step='customer';st.cust=null;st.phone='';st.plans=[];st.versionId=null;st.preview=null;st.idemKey=null;st.result=null;st.reference='';st.staffConfirmed=false;st.err=null;render();};
  }
  render();
}

/* V279 (owner walkthrough item 4), in the owner's own words: red below a quarter, orange below a
   half, yellow while it is still more gone than not, light green once it is mostly there, and full
   green only for a bottle nobody has poured from. Each entry is [exclusive ceiling, colour, name].
   ONE table, consulted by the one bar renderer, so the list rows, the bottle card and the
   customer's own wallet cannot disagree about what "half" looks like. */
const BOTTLE_FILL_BANDS_V279=Object.freeze([
  Object.freeze([25,'#B3453A','red']),
  Object.freeze([50,'#C2701A','orange']),
  Object.freeze([75,'#A8951C','yellow']),
  Object.freeze([100,'#6FAE7C','light green']),
  Object.freeze([101,'#2E7D5B','green'])
]);
function bottleFillToneV279(percent){
  const value=Math.max(0,Math.min(100,Math.round(Number(percent)||0)));
  const band=BOTTLE_FILL_BANDS_V279.find(([ceiling])=>value<ceiling);
  return band?band[1]:'#2E7D5B';
}
function bottleFillBarV275(percent){
  const value=Math.max(0,Math.min(100,Math.round(Number(percent)||0)));
  const tone=bottleFillToneV279(value);
  return `<span class="bottle-fill" role="img" ${workspaceTemplateAttributeV97('aria-label','bottlePercentLeft',{percent:value})} style="display:block;height:9px;min-width:88px;border-radius:999px;background:var(--hair,#ece7e1);overflow:hidden"><span style="display:block;height:100%;width:${value}%;background:${tone}"></span></span>`;
}
function bottleDaysLabelV275(days){
  /* V278: a bottle may now have NO expiry, and the server sends null for it. Number(null) is 0,
     which would have rendered "Last day" on a bottle that never expires — the exact opposite of
     the truth, on the number a bartender acts on. */
  if(days===null||days===undefined||days==='')return 'No expiry';
  const value=Number(days);
  if(!Number.isFinite(value))return '';
  if(value<0)return 'Overdue';
  if(value===0)return 'Last day';
  return `${value} day${value===1?'':'s'} left`;
}
/* ---------- V142 merchant-owned customer payments ---------- */
async function loadMerchantPaymentsV142(){
  const wrap=$('merchantPaymentsWrapV142');if(!wrap||!S.biz?.id)return;
  wrap.setAttribute('aria-busy','true');
  const {data,error}=await sb.rpc('get_merchant_payment_status_v142',{p_business:S.biz.id});
  if(!wrap.isConnected)return;
  wrap.setAttribute('aria-busy','false');
  if(error||!data){
    wrap.innerHTML=CUI.errorState({title:'Customer payments unavailable',message:'Payment setup could not be loaded. No customer payment was affected.',retryId:'merchantPaymentsRetryV142'});
    $('merchantPaymentsRetryV142').onclick=loadMerchantPaymentsV142;return;
  }
  const state=data.status||'not_set_up';
  const ready=data.paynow_ready===true;
  const stateCopy=ready
    ?{label:'Ready',pill:'ok',title:'Ready to accept PayNow',body:'Staff can create a fixed-amount PayNow QR from Record sale. Customer money goes to this business’s connected Stripe account.'}
    :state==='restricted'
      ?{label:'Restricted',pill:'off',title:'Stripe needs attention',body:'Customer PayNow QR is unavailable until Stripe clears the account restriction.'}
      :state==='more_information_needed'
        ?{label:'More information needed',pill:'new',title:'Finish Stripe setup',body:'Continue the secure Stripe form to complete business, representative or payout-bank requirements.'}
        :{label:'Not set up',pill:'off',title:'Accept customer payments',body:'Connect this legal business to Stripe. Branches share the same payout account unless they are separate legal merchants.'};
  wrap.innerHTML=`<div class="row"><div><h2 style="margin:0">Customer payments</h2><p class="muted small" style="margin-top:5px">Separate from your Peekaa subscription.</p></div><span class="spacer"></span><span class="pill ${stateCopy.pill}">${stateCopy.label}</span></div>
    <div class="imp-note" style="margin-top:16px"><b>${stateCopy.title}</b><p class="small" style="margin-top:6px">${stateCopy.body}</p></div>
    <ol class="small" style="line-height:1.75;margin:16px 0 0;padding-left:20px"><li>Owner completes Stripe-hosted identity and bank setup.</li><li>Staff enters a sale and taps <b>PayNow QR</b>.</li><li>Customer scans the locked amount; only Stripe confirmation completes the sale and receipt.</li></ol>
    ${ready?'<p class="muted small" style="margin-top:16px">No API keys or bank details are stored in Peekaa. Manage legal or payout changes through Stripe.</p>'
      :`<button type="button" class="btn" id="merchantPaymentsSetupV142" style="margin-top:18px">${state==='not_set_up'?'Set up Stripe':'Continue Stripe setup'}</button>`}
    <div id="merchantPaymentsStatusV142" role="status" aria-live="polite"></div>`;
  const setup=$('merchantPaymentsSetupV142');if(!setup)return;
  setup.onclick=async()=>{
    setup.disabled=true;setup.textContent='Opening Stripe…';
    const slot=`peekaa:v142:connect:${S.biz.id}`;
    let key='';try{key=sessionStorage.getItem(slot)||''}catch{}
    if(!/^[0-9a-f-]{36}$/i.test(key)){key=crypto.randomUUID();try{sessionStorage.setItem(slot,key)}catch{}}
    const executed=await sb.functions.invoke('stripe-connect-command',{body:{
      action:'create_onboarding_link',business_id:S.biz.id,idempotency_key:key
    }});
    if(!wrap.isConnected)return;
    if(executed.error||!executed.data?.redirect_url){
      setup.disabled=false;setup.textContent=state==='not_set_up'?'Set up Stripe':'Continue Stripe setup';
      $('merchantPaymentsStatusV142').innerHTML='<div class="err" role="alert">Stripe setup could not open. Try again; no account will be duplicated.</div>';return;
    }
    try{sessionStorage.removeItem(slot)}catch{}
    location.assign(executed.data.redirect_url);
  };
}
/* ---------- public customer portal ---------- */
function contrastSafeBrandColor(value){
  const fallback='#C24135';
  if(!/^#[0-9A-Fa-f]{6}$/.test(value||''))return fallback;
  const channels=[1,3,5].map(offset=>parseInt(value.slice(offset,offset+2),16)/255)
    .map(channel=>channel<=.04045?channel/12.92:((channel+.055)/1.055)**2.4);
  const luminance=.2126*channels[0]+.7152*channels[1]+.0722*channels[2];
  return 1.05/(luminance+.05)>=4.5?value.toUpperCase():fallback;
}
async function boot(){
  try{await consumeBusinessOAuthRedirect()}catch{}
  try{await consumePasswordRecoveryRedirect()}catch{}
  loadBuildIdentity();
  route();
}
/* Startup split: the page-scoped bundles (platform console, growth, media
   sync, native bridge, push) are deferred so the document parses and the
   #root skeleton paints without them. Deferred scripts execute before
   DOMContentLoaded, so booting on that event preserves the original
   execution order exactly while removing ~1MB of JS from the parser's
   critical path. */
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>{boot()});
else boot();

