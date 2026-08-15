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
/* V322 (R6): the Rewards Programme page's live on/off switches. Module-level for the same reason
   growTopicV229 is — growPage re-renders by re-calling itself, so anything held in its closure is
   lost between the press and the confirmation the ruling requires. `pending` is the kind awaiting
   that confirmation, `error` the last failed switch, both cleared by the router. */
let growSwitchPendingV322='';
let growSwitchErrorV322='';
/* V324 (owner markup on the Limited Offer page, 2026-08-14): three named buckets — Published,
   Draft, History — replacing the flat list. Module-level for the same reason as above: switching
   tabs re-renders growPage from scratch. Cleared by the router alongside growTopicV229 so leaving
   the page and coming back always opens on Published. */
let growOffersTabV324='published';
/* V324 (owner: apply the same Published/Draft/History split to Point system's own reward
   catalogue). The three groups already existed as data — rewardCardsV250 (live/scheduled/paused),
   growPendingNewRewardsV268 (created in the current draft, never published) and
   rewardHistoryCardsV294 (ended or retired) — merged into one grid with History collapsed
   underneath. This only changes which one is showing; none of the three lists themselves moved,
   so their card markup, click routing and the growTemplatesOpen flow are untouched. */
let growPointsRewardTabV324='published';
/* V326 (owner 5-photo Points System flow, photo 3): the new dedicated #/grow/points page.
   Published/History only — no Draft, since every gift change here is immediate-write
   (business_set_reward_paused_v326/business_delete_reward_v326/business_create_reward_v326),
   never a draft. growPointsDeletePendingV326 holds the id of a gift with its delete confirm
   open (mirrors growSwitchPendingV322's one-open-at-a-time pattern). growPointsAddOpenV326 is
   ''|'form'|'prompt' — closed, the name+points add-gift form open, or the post-save "add
   another?" prompt; growPointsAddDraftV326 holds the in-progress form values across re-renders.
   growPointsBusyV326 guards against double-submit while an RPC is in flight. All cleared by the
   router alongside the other grow session state. */
let growPointsManageTabV326='published';
let growPointsDeletePendingV326='';
let growPointsAddOpenV326='';
let growPointsAddDraftV326={name:'',points:''};
let growPointsErrorV326='';
let growPointsBusyV326=false;
/* V331 — the same shape as the V326 points-page state above, for the new #/grow/tiers page. */
let growTiersManageTabV331='published';
let growTiersDeletePendingV331='';
let growTiersAddOpenV331='';
let growTiersAddDraftV331={name:'',threshold:''};
let growTiersErrorV331='';
let growTiersBusyV331=false;
let settingsActiveTab='modules';
let profileOpen=false;
let customerUiObserver=null;
let routeDispose=()=>{};
let activeCustomerRedemptionCleanup=()=>{};
let activeCustomerWalletLiveCleanupV295=()=>{};
function disposeCurrentRoute(){
  const dispose=routeDispose;routeDispose=()=>{};
  dispose({restoreFocus:false});
  activeMerchantScannerCleanup();
  activeCustomerRedemptionCleanup({restoreFocus:false});
  activeCustomerJoinScannerCleanup({restoreFocus:false});
  activeCustomerWalletLiveCleanupV295();
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

/* V314 (W6 increment 1): `programmes` is this session's mirror of public.business_programmes —
   the four-row programme spine that became the ONE authority on which programmes run when v314
   dropped the v308 sync triggers. It is cached exactly like myModules (fetched once per business,
   see route()), refreshed from the server after every public.set_programmes_v314 call, and NEVER
   flipped optimistically: an optimistic flip is precisely how businesses.points_mode came to lie
   after the tripwire started swallowing writes to it. null = not read yet or unreadable, in which
   case every reader falls back to the frozen legacy columns rather than guessing. */
let S={user:null,biz:null,charts:[],myModules:null,myModulePerms:null,myRole:null,isSA:false,saChecked:false,hasCustomerPersona:null,staffWorkspaces:[],customerProfile:null,programmes:null,programmesBusinessId:null};

function programmeSpineRowsV314(){
  return Array.isArray(S.programmes)&&S.programmesBusinessId&&S.biz&&S.programmesBusinessId===S.biz.id
    ?S.programmes:null;
}
async function refreshProgrammeSpineV314(){
  if(!S.biz?.id)return null;
  const {data,error}=await sb.from('business_programmes').select('kind,active').eq('business_id',S.biz.id);
  if(error)return null;
  S.programmes=(data||[]).map(row=>({kind:row?.kind||null,active:row?.active===true}));
  S.programmesBusinessId=S.biz.id;
  return S.programmes;
}
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
  S={user:null,biz:null,charts:[],myModules:null,myModulePerms:null,myRole:null,isSA:false,saChecked:false,hasCustomerPersona:null,staffWorkspaces:[],customerProfile:null,programmes:null,programmesBusinessId:null};
  /* V286: the nav badge cache is per-person. Left standing, customer B's Rewards/Bookings tabs
     first-painted with customer A's counts on a shared phone until the wallet data landed. */
  customerNavCountsV194={programmes:0,bookings:0};
  customerFeatureCapabilities=null;customerPhoneOtpCapabilities=null;customerRelationshipSyncState={userId:null,attempted:false,result:null};pendingCustomerInvitationToken=invitation;rememberPendingCustomerJoinToken(joinToken);pendingCustomerBusinessSlug='';rememberPendingCustomerDestination(destination);selectedBranchId=null;profileOpen=false;
  pendingCustomerSearch='';pendingTillPhone='';pendingApptClientId='';pendingOpenApptFormV217=false;settingsActiveTab='modules';growTopicV229='';growSwitchPendingV322='';growSwitchErrorV322='';growOffersTabV324='published';growPointsRewardTabV324='published';growPointsManageTabV326='published';growPointsDeletePendingV326='';growPointsAddOpenV326='';growPointsAddDraftV326={name:'',points:''};growPointsErrorV326='';growPointsBusyV326=false;growTiersManageTabV331='published';growTiersDeletePendingV331='';growTiersAddOpenV331='';growTiersAddDraftV331={name:'',threshold:''};growTiersErrorV331='';growTiersBusyV331=false;
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
      const platformRenderedV298=await platformConsole.render({
        root,sb,CUI,brand:BRAND,hash:h,isCurrent:isRouteCurrent,workspaceHash,
        onSignOut:async()=>{
          killChannels();await sb.auth.signOut();resetClientSessionState();nav('#/');
        }
      });
      /* V298 (owner report 2026-08-13 — a card title printed twice, once as the heading and again
         as the table's caption). The console never calls CUI.mountMain, so the workspace fix in
         enhanceTables cannot reach it; this attaches the caption rule on its own, which is the
         only part of the enhancer that is safe to run over console markup. It reuses
         customerUiObserver so leaving for a workspace route disconnects it at shell render, and
         the disconnect above covers console route to console route. */
      if(customerUiObserver)customerUiObserver.disconnect();
      customerUiObserver=CUI.observeTableCaptionsV298(root);
      return platformRenderedV298;
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
    /* V314 (W6 increment 1): the programme spine, cached once per business exactly like
       S.myModules above. Every owner surface that used to ask businesses.points_mode or
       loyalty_programs.active "is this programme running?" asks this instead — those two columns
       became SETTINGS at v314 and can no longer answer it. Fail-soft and retried on the next
       route: a failed read leaves S.programmes null and each reader falls back to the legacy
       column rather than inventing a state. */
    if(programmeSpineRowsV314()===null&&S.myModules&&S.myModules.includes('loyalty')){
      await refreshProgrammeSpineV314();
      if(!isRouteCurrent())return;
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
    /* V303 (owner 2026-08-13: "remove gift cards from the business UI entirely"). Hiding the nav
       row is not the boundary — a bookmark or a typed hash still resolves — so the route is
       refused here, in the same place and the same shape as the storedvalue refusal above, and it
       says so rather than silently rendering the dashboard. The page function and every gift-card
       RPC are left in place: this is a surface decision, and nothing about existing cards, their
       balances or their ledger rows changes. */
    if(pageKey==='giftcards'){
      toast('Gift cards are no longer part of this workspace.');
      return nav('#/dashboard');
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
const CUSTOMER_LOCALES=Object.freeze(['en','zh-CN','ms','ta']);
const CUSTOMER_COPY=Object.freeze({
  en:Object.freeze({
    home:'Home',programmes:'My Rewards',rewardsTab:'Rewards',explore:'Explore',bookings:'Bookings',scanQr:'Scan QR',profileTab:'Profile',
    notifications:'Notifications',accountMenu:'Open account menu',profilePasskeys:'Profile & passkeys',signOut:'Sign out',
    language:'Language',english:'English',chinese:'简体中文',backProgrammes:'Back to My Rewards',
    chooseProgramme:'Choose a reward business',yourProgrammes:'My Rewards',
    programmesIntro:'Pick a business to open its rewards, benefits, bookings and activity.',
    addProgramme:'Scan to join',openProgramme:'Open {business} rewards',localBusiness:'Local business',
    referralHeading:'Give a friend {business}',
    /* v322 (owner ruling R1/R4): "no more store credits" — a referral pays POINTS. {reward} is now
       a points phrase from customerReferralPointsV322, not a money amount; {floor} is still money,
       because the friend still has to spend. */
    referralTermsWithFloor:'They quote your code when they join. Once they spend {floor}, you get {reward}.',
    referralTerms:'They quote your code when they join. After their first spend, you get {reward}.',
    referralPoints:'{count} points',
    referralOnePoint:'1 point',
    yourReferralCode:'Your referral code',copyCode:'Copy',shareCode:'Share',codeCopied:'Code copied.',
    referralCodePending:'Your code is being prepared — ask the team at the counter.',
    referredCount:'Friends who joined and spent through you: {count}',
    shareYourCode:'Share your code',
    referralShareMessage:'Come join me at {business} — quote my code {code} when you sign up at the counter.',
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
    merchantProgramme:'{business} rewards',featured:'Menu',
    noFeatured:'This business has not published featured items yet.',
    /* v295: wallet detail sections + claim flow. */
    'Transactions & points':'Transactions & points',
    'Recent activity':'Recent activity',
    'Full history':'Full history',
    'Rate your visit':'Rate your visit',
    'Your latest events with this business.':'Your latest events with this business.',
    'Your review helps other people find this business.':'Your review helps other people find this business.',
    'No purchases or points activity has been recorded for this programme yet.':'No purchases or points activity has been recorded for this programme yet.',
    'Every purchase, reversal, correction, and points event kept in time order.':'Every purchase, reversal, correction, and points event kept in time order.',
    'Loyalty activity':'Loyalty activity',
    'Your loyalty history with this business.':'Your loyalty history with this business.',
    'Gift cards':'Gift cards',
    'Money left on your gift cards from this business.':'Money left on your gift cards from this business.',
    'Show this screen at the counter — the team uses your card there. We never show the full card number.':'Show this screen at the counter — the team uses your card there. We never show the full card number.',
    'Packages':'Packages',
    'Session balances and recent usage.':'Session balances and recent usage.',
    'Membership':'Membership',
    'Current plan and period status.':'Current plan and period status.',
    'Appointments':'Appointments',
    'Upcoming and recent visits.':'Upcoming and recent visits.',
    'Your bottles':'Your bottles',
    'What {business} is keeping for you. Show this screen at the counter to have one brought out.':'What {business} is keeping for you. Show this screen at the counter to have one brought out.',
    'this bar':'this bar',
    'Load more':'Load more',
    'Pending with business':'Pending with business',
    'Ready to use':'Ready to use',
    'All used up':'All used up',
    'Not valid':'Not valid',
    'This section':'This section',
    '{section} didn’t load':'{section} didn’t load',
    'Your sign-in expired. Sign in again.':'Your sign-in expired. Sign in again.',
    'Sign in':'Sign in',
    'Book again':'Book again',
    'Open programme':'Open programme',
    'Withdraw':'Withdraw',
    'Waitlisted':'Waitlisted',
    'Pending':'Pending',
    'Appointment':'Appointment',
    'Add a business programme':'Add a business programme',
    'Accept invitation':'Accept invitation',
    'Confirm this private invitation while signed in to the intended account.':'Confirm this private invitation while signed in to the intended account.',
    'Enter the business link from its QR or invitation. We only connect an exact unclaimed record.':'Enter the business link from its QR or invitation. We only connect an exact unclaimed record.',
    'Use the same confirmed email your business has on file.':'Use the same confirmed email your business has on file.',
    'Checking access…':'Checking access…',
    'How should we find your record?':'How should we find your record?',
    'Use my verified mobile number':'Use my verified mobile number',
    'Use my confirmed email instead':'Use my confirmed email instead',
    'Business link':'Business link',
    'Claim':'Claim',
    'Checking…':'Checking…',
    'Customer access could not be checked.':'Customer access could not be checked.',
    'Customer access is unavailable. Please try again later.':'Customer access is unavailable. Please try again later.',
    'Choose where to continue':'Choose where to continue',
    'Wallet links:':'Wallet links:',
    'Staff workspaces:':'Staff workspaces:',
    'No wallet links yet.':'No wallet links yet.',
    'Linked':'Linked',
    'Request received':'Request received',
    'Your wallet is ready.':'Your wallet is ready.',
    'If the details match an available customer record, the business link will appear here.':'If the details match an available customer record, the business link will appear here.',
    'Open wallet':'Open wallet',
    /* v295: Communications (PDPA consent) + profile consent cluster. */
    'Communications':'Communications',
    'Loading your communication choices…':'Loading your communication choices…',
    'Your communication choices could not be loaded. Nothing has been changed.':'Your communication choices could not be loaded. Nothing has been changed.',
    'No communication choices yet':'No communication choices yet',
    'There is nothing to set here for your account right now.':'There is nothing to set here for your account right now.',
    'Everything is on unless you turn it off. Turning something off here never stops receipts, booking confirmations or security messages — those are not marketing and keep sending.':'Everything is on unless you turn it off. Turning something off here never stops receipts, booking confirmations or security messages — those are not marketing and keep sending.',
    'Send me all marketing messages':'Send me all marketing messages',
    'One tick covers every category and every channel below — push, email, SMS, WhatsApp and calls. You can switch any single one back off at any time.':'One tick covers every category and every channel below — push, email, SMS, WhatsApp and calls. You can switch any single one back off at any time.',
    'Saving…':'Saving…',
    'That choice could not be saved, so it has been put back. Please try again.':'That choice could not be saved, so it has been put back. Please try again.',
    'Saved.':'Saved.',
    'That change could not be saved, so your choices have been put back. Please try again.':'That change could not be saved, so your choices have been put back. Please try again.',
    'All marketing messages are on.':'All marketing messages are on.',
    'All marketing messages are off. Receipts, bookings and security messages still send.':'All marketing messages are off. Receipts, bookings and security messages still send.',
    'Offers from businesses you follow':'Offers from businesses you follow',
    'Promotions and deals from the businesses whose programmes you have joined.':'Promotions and deals from the businesses whose programmes you have joined.',
    'Your rewards and points':'Your rewards and points',
    'Points you earn, rewards unlocked, and value that is about to expire.':'Points you earn, rewards unlocked, and value that is about to expire.',
    'Peekaa updates':'Peekaa updates',
    'News and new features from Peekaa itself.':'News and new features from Peekaa itself.',
    'In-app message':'In-app message',
    'Push notification':'Push notification',
    'Email':'Email',
    'SMS':'SMS',
    'WhatsApp':'WhatsApp',
    'Call':'Call',
    'Marketing choices':'Marketing choices',
    'Offers and updates from Nestly Technologies Pte. Ltd., the company behind {product}, and its partners, by push notification, in-app message, email, SMS, WhatsApp, phone call and other marketing channels. Your name and contact details may be shared with {product}’s partners for marketing purposes only. This is separate from messages sent by individual businesses.':'Offers and updates from Nestly Technologies Pte. Ltd., the company behind {product}, and its partners, by push notification, in-app message, email, SMS, WhatsApp, phone call and other marketing channels. Your name and contact details may be shared with {product}’s partners for marketing purposes only. This is separate from messages sent by individual businesses.',
    'Yes — send me these offers and updates. I can turn this off here, or in {link}, at any time. {product} stops sending straight away. Partners are told to stop within 10 business days. Turning it off does not affect my points, bookings or service messages.':'Yes — send me these offers and updates. I can turn this off here, or in {link}, at any time. {product} stops sending straight away. Partners are told to stop within 10 business days. Turning it off does not affect my points, bookings or service messages.',
    'Save marketing choice':'Save marketing choice',
    'Your marketing choice could not be loaded. No change has been made.':'Your marketing choice could not be loaded. No change has been made.',
    'Choose what you hear about and how — offers from businesses you follow, your rewards and points, and Peekaa updates.':'Choose what you hear about and how — offers from businesses you follow, your rewards and points, and Peekaa updates.',
    'Open communications':'Open communications',
    'Your consent history':'Your consent history',
    'Every marketing choice you have made, newest first. This is a record only — to change something, open Communications above.':'Every marketing choice you have made, newest first. This is a record only — to change something, open Communications above.',
    'Loading your consent history…':'Loading your consent history…',
    preferredLanguage:'Preferred language',
    languageHelp:'{product} follows this choice in English, 中文, Bahasa Melayu and தமிழ்.',
    profileSaved:'Profile saved.',
    /* v310 (W4b): the programme STACK. One card per programme the firm actually runs, each with
       one figure and one sentence. These are the first programme sentences written for all four
       languages from the start — the tab surface they replace is English-only (card titles
       hard-coded in customerProgrammeSummaryTabsV194, the reward line in
       customerRewardProgressMarkupV167, the distance line inside customerTierPanelMarkupV194,
       the paused sentence in customerProgrammePointsPanelV230). The v194 fallback path keeps its
       English exactly as shipped; only the stack speaks all four. */
    stampsCardTitle:'Stamp card',
    pointsCardTitle:'Points & gifts',
    tierCardTitle:'Tier',
    stampsRemaining:'{count} more stamps and your next {gift} is on us.',
    stampsReady:'Your next {gift} is ready — show this at the counter.',
    stampsNoGift:'{count} stamps collected.',
    /* v323 (R5) — the quest. Claiming a milestone no longer spends the stamps, so the card has a
       length, a position on it, and a list of what has already been collected on THIS card. */
    stampsQuestProgress:'{filled} of {total} stamps on this card.',
    stampsQuestCarried:'{count} already counted toward your next card.',
    stampsQuestClaimed:'Collected on this card',
    stampsQuestAllClaimed:'Every gift on this card is collected.',
    stampsQuestRetired:'This stamp card has been retired — ask us about your balance.',
    pointsRemaining:'{count} more for {gift}.',
    pointsReady:'{gift} is ready to claim.',
    tierDistance:'{count} more {unit} to {tier}.',
    tierTop:'You’re at the top tier.',
    tierUnitVisits:'visits',
    tierUnitPoints:'points',
    tierUnitSpent:'spent',
    programmePaused:'Programme paused',
    programmePausedBody:'Nothing is being counted right now. Anything you already earned is kept.',
    claimableNow:'Ready now',
    claimableCount:'{count} ready to claim',
    /* Shipped with the W4c slot the stack renders below the strip, so W4c is markup and wiring
       only. No member identifier exists on this surface yet and the counter scanner parses three
       prefixes, none of them an identity — a QR the counter cannot scan is worse than no QR. */
    showMyCode:'Show my code',
    showMyCodeBody:'Show this to the team at the counter.'
  }),
  'zh-CN':Object.freeze({
    home:'首页',programmes:'我的奖励',rewardsTab:'奖励',explore:'发现',bookings:'预约',scanQr:'扫码',profileTab:'我的',
    notifications:'通知',accountMenu:'打开账户菜单',profilePasskeys:'个人资料与通行密钥',signOut:'退出登录',
    language:'语言',english:'English',chinese:'简体中文',backProgrammes:'返回我的奖励',
    chooseProgramme:'选择一家奖励商家',yourProgrammes:'我的奖励',
    programmesIntro:'选择一家商家，查看它的奖励、权益、预约和活动记录。',
    addProgramme:'扫码加入',openProgramme:'打开{business}的奖励',localBusiness:'本地商家',
    referralHeading:'介绍朋友到{business}',
    referralTermsWithFloor:'朋友加入时报上您的代码。他们消费满{floor}后，您可获得{reward}。',
    referralTerms:'朋友加入时报上您的代码。他们首次消费后，您可获得{reward}。',
    referralPoints:'{count}积分',
    referralOnePoint:'1积分',
    yourReferralCode:'您的推荐码',copyCode:'复制',shareCode:'分享',codeCopied:'已复制代码。',
    referralCodePending:'您的推荐码正在准备中——请到柜台咨询。',
    referredCount:'通过您加入并消费的朋友：{count}',
    shareYourCode:'分享您的推荐码',
    referralShareMessage:'来{business}和我一起吧——在柜台注册时报上我的代码{code}。',
    rewardReady:'奖励已就绪 — 打开即可兑换。',continueProgramme:'打开奖励主页，看看接下来能做什么。',
    firstQuest:'你的第一份奖励',scanLoyaltyQr:'扫描会员二维码',
    firstQuestBody:'在参与商家出示的 Peekaa 二维码处扫码。该认证商家会成为你的第一个奖励账户。',
    scanBusinessQr:'扫描商家二维码',qrOnlyHelp:'只能通过商家出示的二维码加入。',
    balance:'余额',nextReward:'下一个奖励',tierProgress:'等级进度',benefits:'权益与优待',
    offers:'生日与节庆优惠',rewards:'奖励',activityHistory:'活动与历史',
    noBenefits:'目前没有额外优待。',noOffers:'目前没有生日或节庆优惠。',
    noRewards:'目前没有可用奖励。',
    retry:'重试',bookNow:'立即预约',requestVisit:'向{business}预约你的下次光临。',
    points:'积分',stamps:'印章',currentTier:'当前等级',nextTier:'下一级：{tier}',
    terms:'条款',availableNow:'现在可用',
    loadingProgramme:'正在加载奖励…',loadingProgrammes:'正在加载我的奖励…',
    successSounds:'成功提示音',soundOff:'默认关闭',soundOn:'开启',
    soundHelp:'可选。系统要求减少动态效果时，提示音保持关闭。',
    merchantProgramme:'{business}的奖励',featured:'菜单',
    noFeatured:'该商家尚未发布精选项目。',
    preferredLanguage:'首选语言',
    languageHelp:'{product} 支持 English、中文、Bahasa Melayu 和 தமிழ்，界面会跟随此选择。',
    profileSaved:'资料已保存。',
    'Rewards are not available for this account.':'此账户暂无法查看奖励。',
    'Rewards could not be loaded.':'奖励加载失败。',
    'Loyalty activity is not available for this account.':'此账户暂无法查看积分活动。',
    'Activity could not be loaded.':'活动记录加载失败。',
    'Transaction history is not available for this account.':'此账户暂无法查看交易记录。',
    'Transaction history could not be loaded.':'交易记录加载失败。',
    'Gift cards are not available for this account.':'此账户暂无法查看礼品卡。',
    'Gift cards could not be loaded.':'礼品卡加载失败。',
    'Packages are not available for this account.':'此账户暂无法查看套餐。',
    'Packages could not be loaded.':'套餐加载失败。',
    'Membership is not available for this account.':'此账户暂无法查看会员资格。',
    'Membership could not be loaded.':'会员资格加载失败。',
    'Appointments are not available for this account.':'此账户暂无法查看预约。',
    'Appointments could not be loaded.':'预约加载失败。',
    'No rewards are available right now.':'目前没有可用奖励。',
    'No loyalty activity is available yet.':'暂无积分活动。',
    'No packages are available for this account.':'此账户没有可用套餐。',
    'No membership is available for this account.':'此账户没有会员资格。',
    'No appointments are available yet.':'暂无预约。',
    'Scan the business QR':'扫描商家二维码',
    'Use the Peekaa QR displayed by the business. A scan never joins an unrelated business.':'请使用商家出示的 Peekaa 二维码。扫码不会加入无关商家。',
    'Close scanner':'关闭扫码器',
    'Camera preview for business join QR':'商家加入二维码的相机预览',
    'Open camera':'打开相机',
    "Can't scan? Use a photo or link":'无法扫码？使用照片或链接',
    'Or choose a QR image':'或选择二维码图片',
    'Camera unavailable?':'相机不可用？',
    'Paste the QR link':'粘贴二维码链接',
    'Continue':'继续',
    'That is not an active Peekaa business QR. Ask the business to generate its latest join QR.':'这不是有效的 Peekaa 商家二维码。请商家生成最新的加入二维码。',
    'Camera is unavailable in this browser. Choose a QR image or paste the QR link.':'此浏览器无法使用相机。请选择二维码图片或粘贴二维码链接。',
    'Starting camera…':'正在启动相机…',
    'The scanner could not load. Check your connection and try again.':'扫码器加载失败。请检查网络后重试。',
    'Point the camera at the business QR.':'将相机对准商家二维码。',
    'Camera access was not available. Choose a QR image or paste the QR link.':'无法访问相机。请选择二维码图片或粘贴二维码链接。',
    'Reading QR image…':'正在读取二维码图片…',
    'No active Peekaa join QR was found in that image.':'图片中未找到有效的 Peekaa 加入二维码。',
    'That image could not be read. Try a clearer QR image.':'无法读取该图片。请尝试更清晰的二维码图片。',
    /* v295: wallet detail sections + claim flow. */
    'Transactions & points':'交易与积分',
    'Recent activity':'最近动态',
    'Full history':'完整记录',
    'Rate your visit':'评价这次光临',
    'Your latest events with this business.':'您在本店的最新记录。',
    'Your review helps other people find this business.':'您的评价能帮助更多人找到这家店。',
    'No purchases or points activity has been recorded for this programme yet.':'此计划还没有任何消费或积分记录。',
    'Every purchase, reversal, correction, and points event kept in time order.':'每一笔购买、冲正、更正和积分事件均按时间顺序保存。',
    'Loyalty activity':'积分活动',
    'Your loyalty history with this business.':'你在该商家的积分历史。',
    'Gift cards':'礼品卡',
    'Money left on your gift cards from this business.':'该商家礼品卡的剩余金额。',
    'Show this screen at the counter — the team uses your card there. We never show the full card number.':'请在柜台出示此屏幕——工作人员会在那里使用你的卡。我们从不显示完整卡号。',
    'Packages':'套餐',
    'Session balances and recent usage.':'剩余次数和近期使用情况。',
    'Membership':'会员资格',
    'Current plan and period status.':'当前方案和周期状态。',
    'Appointments':'预约',
    'Upcoming and recent visits.':'即将到来和近期的到店记录。',
    'Your bottles':'你的存酒',
    'What {business} is keeping for you. Show this screen at the counter to have one brought out.':'{business} 为你保管的物品。在柜台出示此屏幕即可取出。',
    'this bar':'这家酒吧',
    'Load more':'加载更多',
    'Pending with business':'等待商家处理',
    'Ready to use':'可以使用',
    'All used up':'已用完',
    'Not valid':'无效',
    'This section':'此部分',
    '{section} didn’t load':'{section}加载失败',
    'Your sign-in expired. Sign in again.':'你的登录已过期。请重新登录。',
    'Sign in':'登录',
    'Book again':'再次预约',
    'Open programme':'打开方案',
    'Withdraw':'撤回',
    'Waitlisted':'已加入候补',
    'Pending':'待处理',
    'Appointment':'预约',
    'Add a business programme':'添加商家方案',
    'Accept invitation':'接受邀请',
    'Confirm this private invitation while signed in to the intended account.':'请在登录目标账户的状态下确认此私人邀请。',
    'Enter the business link from its QR or invitation. We only connect an exact unclaimed record.':'请输入商家二维码或邀请中的链接。我们只会连接完全匹配且未被认领的记录。',
    'Use the same confirmed email your business has on file.':'请使用商家存档中已确认的同一邮箱。',
    'Checking access…':'正在检查访问权限…',
    'How should we find your record?':'我们该如何找到你的记录？',
    'Use my verified mobile number':'使用我已验证的手机号码',
    'Use my confirmed email instead':'改用我已确认的邮箱',
    'Business link':'商家链接',
    'Claim':'认领',
    'Checking…':'正在检查…',
    'Customer access could not be checked.':'无法检查顾客访问权限。',
    'Customer access is unavailable. Please try again later.':'顾客访问暂不可用。请稍后重试。',
    'Choose where to continue':'选择继续的位置',
    'Wallet links:':'钱包链接：',
    'Staff workspaces:':'员工工作区：',
    'No wallet links yet.':'暂无钱包链接。',
    'Linked':'已关联',
    'Request received':'请求已收到',
    'Your wallet is ready.':'你的钱包已就绪。',
    'If the details match an available customer record, the business link will appear here.':'如果信息与可用的顾客记录匹配，商家链接会显示在此处。',
    'Open wallet':'打开钱包',
    /* v295: Communications (PDPA consent) + profile consent cluster. */
    'Communications':'通讯设置',
    'Loading your communication choices…':'正在加载你的通讯选择…',
    'Your communication choices could not be loaded. Nothing has been changed.':'无法加载你的通讯选择。未做任何更改。',
    'No communication choices yet':'暂无通讯选择',
    'There is nothing to set here for your account right now.':'你的账户目前无需在此设置任何内容。',
    'Everything is on unless you turn it off. Turning something off here never stops receipts, booking confirmations or security messages — those are not marketing and keep sending.':'除非你关闭，否则全部开启。在此关闭任何项目都不会停止收据、预约确认或安全消息——这些不属于营销消息，会继续发送。',
    'Send me all marketing messages':'向我发送所有营销消息',
    'One tick covers every category and every channel below — push, email, SMS, WhatsApp and calls. You can switch any single one back off at any time.':'勾选一次即涵盖下方所有类别和渠道——推送、邮件、短信、WhatsApp 和来电。你可以随时单独关闭其中任何一项。',
    'Saving…':'正在保存…',
    'That choice could not be saved, so it has been put back. Please try again.':'该选择保存失败，已恢复原状。请重试。',
    'Saved.':'已保存。',
    'That change could not be saved, so your choices have been put back. Please try again.':'该更改保存失败，你的选择已恢复原状。请重试。',
    'All marketing messages are on.':'所有营销消息已开启。',
    'All marketing messages are off. Receipts, bookings and security messages still send.':'所有营销消息已关闭。收据、预约和安全消息仍会发送。',
    'Offers from businesses you follow':'你关注商家的优惠',
    'Promotions and deals from the businesses whose programmes you have joined.':'来自你已加入方案的商家的促销和优惠。',
    'Your rewards and points':'你的奖励和积分',
    'Points you earn, rewards unlocked, and value that is about to expire.':'你赚取的积分、已解锁的奖励，以及即将到期的价值。',
    'Peekaa updates':'Peekaa 更新',
    'News and new features from Peekaa itself.':'来自 Peekaa 本身的消息和新功能。',
    'In-app message':'应用内消息',
    'Push notification':'推送通知',
    'Email':'电子邮件',
    'SMS':'短信',
    'WhatsApp':'WhatsApp',
    'Call':'来电',
    'Marketing choices':'营销选择',
    'Offers and updates from Nestly Technologies Pte. Ltd., the company behind {product}, and its partners, by push notification, in-app message, email, SMS, WhatsApp, phone call and other marketing channels. Your name and contact details may be shared with {product}’s partners for marketing purposes only. This is separate from messages sent by individual businesses.':'来自 {product} 背后的公司 Nestly Technologies Pte. Ltd. 及其合作伙伴的优惠和更新，通过推送通知、应用内消息、电子邮件、短信、WhatsApp、电话及其他营销渠道发送。你的姓名和联系方式可能仅出于营销目的与 {product} 的合作伙伴共享。这与各商家自行发送的消息无关。',
    'Yes — send me these offers and updates. I can turn this off here, or in {link}, at any time. {product} stops sending straight away. Partners are told to stop within 10 business days. Turning it off does not affect my points, bookings or service messages.':'是——请向我发送这些优惠和更新。我可以随时在此处或在{link}中关闭。{product} 会立即停止发送。合作伙伴将被要求在 10 个工作日内停止。关闭此项不会影响我的积分、预约或服务消息。',
    'Save marketing choice':'保存营销选择',
    'Your marketing choice could not be loaded. No change has been made.':'无法加载你的营销选择。未做任何更改。',
    'Choose what you hear about and how — offers from businesses you follow, your rewards and points, and Peekaa updates.':'选择你想了解的内容和方式——你关注商家的优惠、你的奖励和积分，以及 Peekaa 更新。',
    'Open communications':'打开通讯设置',
    'Your consent history':'你的同意记录',
    'Every marketing choice you have made, newest first. This is a record only — to change something, open Communications above.':'你做过的每一项营销选择，最新在前。这仅为记录——如需更改，请打开上方的通讯设置。',
    'Loading your consent history…':'正在加载你的同意记录…',
    /* v310 (W4b) programme stack. */
    stampsCardTitle:'集章卡',
    pointsCardTitle:'积分与礼品',
    tierCardTitle:'会员等级',
    stampsRemaining:'再集 {count} 个章，下一份{gift}就由我们请客。',
    stampsReady:'你的{gift}已可领取——请在柜台出示。',
    stampsNoGift:'已集 {count} 个章。',
    /* v323 (R5) — the quest. */
    stampsQuestProgress:'这张卡已集 {filled}/{total} 个章。',
    stampsQuestCarried:'另有 {count} 个章已计入下一张卡。',
    stampsQuestClaimed:'本卡已领取',
    stampsQuestAllClaimed:'这张卡上的礼品都已领取。',
    stampsQuestRetired:'这张集章卡已停用——请向我们查询你的余额。',
    pointsRemaining:'再要 {count} 即可换{gift}。',
    pointsReady:'{gift}已可领取。',
    tierDistance:'再要 {count} {unit}即可升到{tier}。',
    tierTop:'你已在最高等级。',
    tierUnitVisits:'次到访',
    tierUnitPoints:'积分',
    tierUnitSpent:'消费',
    programmePaused:'计划已暂停',
    programmePausedBody:'目前不再计入任何新记录。你已获得的一切都会保留。',
    claimableNow:'现在可领取',
    claimableCount:'{count} 项可领取',
    showMyCode:'出示我的代码',
    showMyCodeBody:'请向柜台的工作人员出示。'
  }),
  ms:Object.freeze({
    home:'Laman Utama',programmes:'Ganjaran Saya',rewardsTab:'Ganjaran',explore:'Terokai',bookings:'Tempahan',scanQr:'Imbas QR',profileTab:'Profil',
    notifications:'Pemberitahuan',accountMenu:'Buka menu akaun',profilePasskeys:'Profil & kunci laluan',signOut:'Log keluar',
    language:'Bahasa',english:'English',chinese:'简体中文',backProgrammes:'Kembali ke Ganjaran Saya',
    chooseProgramme:'Pilih perniagaan ganjaran',yourProgrammes:'Ganjaran Saya',
    programmesIntro:'Pilih perniagaan untuk membuka ganjaran, manfaat, tempahan dan aktivitinya.',
    addProgramme:'Imbas untuk sertai',openProgramme:'Buka ganjaran {business}',localBusiness:'Perniagaan tempatan',
    referralHeading:'Perkenalkan rakan kepada {business}',
    referralTermsWithFloor:'Rakan anda sebut kod anda semasa mendaftar. Selepas mereka berbelanja {floor}, anda dapat {reward}.',
    referralTerms:'Rakan anda sebut kod anda semasa mendaftar. Selepas belanja pertama mereka, anda dapat {reward}.',
    referralPoints:'{count} mata',
    referralOnePoint:'1 mata',
    yourReferralCode:'Kod rujukan anda',copyCode:'Salin',shareCode:'Kongsi',codeCopied:'Kod disalin.',
    referralCodePending:'Kod anda sedang disediakan — tanya kaunter.',
    referredCount:'Rakan yang sertai dan berbelanja melalui anda: {count}',
    shareYourCode:'Kongsi kod anda',
    referralShareMessage:'Jom sertai saya di {business} — sebut kod saya {code} semasa mendaftar di kaunter.',
    rewardReady:'Ganjaran sedia — buka untuk menebus.',continueProgramme:'Buka laman ganjaran anda untuk melihat langkah seterusnya.',
    firstQuest:'Ganjaran pertama anda',scanLoyaltyQr:'Imbas QR kesetiaan',
    firstQuestBody:'Di perniagaan yang menyertai, imbas QR Peekaa yang dipaparkan di kaunter. Perniagaan yang disahkan itu menjadi akaun ganjaran pertama anda.',
    scanBusinessQr:'Imbas QR perniagaan',qrOnlyHelp:'Perniagaan hanya boleh ditambah dengan QR yang dikeluarkan oleh perniagaan.',
    balance:'Baki',nextReward:'Ganjaran seterusnya',tierProgress:'Kemajuan tahap',benefits:'Manfaat & keistimewaan',
    offers:'Tawaran hari jadi & bermusim',rewards:'Ganjaran',activityHistory:'Aktiviti & sejarah',
    noBenefits:'Tiada keistimewaan tambahan buat masa ini.',noOffers:'Tiada tawaran hari jadi atau bermusim buat masa ini.',
    noRewards:'Tiada ganjaran tersedia buat masa ini.',
    retry:'Cuba lagi',bookNow:'Tempah sekarang',requestVisit:'Mohon lawatan seterusnya dengan {business}.',
    points:'mata',stamps:'setem',currentTier:'Tahap semasa',nextTier:'Seterusnya: {tier}',
    terms:'Terma',availableNow:'Tersedia sekarang',
    loadingProgramme:'Memuatkan ganjaran…',loadingProgrammes:'Memuatkan Ganjaran Saya…',
    successSounds:'Bunyi kejayaan',soundOff:'Dimatikan secara lalai',soundOn:'Hidup',
    soundHelp:'Pilihan. Bunyi kekal dimatikan apabila gerakan dikurangkan diminta.',
    merchantProgramme:'Ganjaran {business}',featured:'Menu',
    noFeatured:'Perniagaan ini belum menerbitkan item pilihan.',
    preferredLanguage:'Bahasa pilihan',
    languageHelp:'{product} mengikut pilihan ini dalam English, 中文, Bahasa Melayu dan தமிழ்.',
    profileSaved:'Profil disimpan.',
    'Rewards are not available for this account.':'Ganjaran tidak tersedia untuk akaun ini.',
    'Rewards could not be loaded.':'Ganjaran tidak dapat dimuatkan.',
    'Loyalty activity is not available for this account.':'Aktiviti kesetiaan tidak tersedia untuk akaun ini.',
    'Activity could not be loaded.':'Aktiviti tidak dapat dimuatkan.',
    'Transaction history is not available for this account.':'Sejarah transaksi tidak tersedia untuk akaun ini.',
    'Transaction history could not be loaded.':'Sejarah transaksi tidak dapat dimuatkan.',
    'Gift cards are not available for this account.':'Kad hadiah tidak tersedia untuk akaun ini.',
    'Gift cards could not be loaded.':'Kad hadiah tidak dapat dimuatkan.',
    'Packages are not available for this account.':'Pakej tidak tersedia untuk akaun ini.',
    'Packages could not be loaded.':'Pakej tidak dapat dimuatkan.',
    'Membership is not available for this account.':'Keahlian tidak tersedia untuk akaun ini.',
    'Membership could not be loaded.':'Keahlian tidak dapat dimuatkan.',
    'Appointments are not available for this account.':'Temu janji tidak tersedia untuk akaun ini.',
    'Appointments could not be loaded.':'Temu janji tidak dapat dimuatkan.',
    'No rewards are available right now.':'Tiada ganjaran tersedia buat masa ini.',
    'No loyalty activity is available yet.':'Belum ada aktiviti kesetiaan.',
    'No packages are available for this account.':'Tiada pakej tersedia untuk akaun ini.',
    'No membership is available for this account.':'Tiada keahlian untuk akaun ini.',
    'No appointments are available yet.':'Belum ada temu janji.',
    'Scan the business QR':'Imbas QR perniagaan',
    'Use the Peekaa QR displayed by the business. A scan never joins an unrelated business.':'Gunakan QR Peekaa yang dipaparkan oleh perniagaan. Imbasan tidak akan menyertai perniagaan yang tiada kaitan.',
    'Close scanner':'Tutup pengimbas',
    'Camera preview for business join QR':'Pratonton kamera untuk QR penyertaan perniagaan',
    'Open camera':'Buka kamera',
    "Can't scan? Use a photo or link":'Tidak dapat mengimbas? Guna foto atau pautan',
    'Or choose a QR image':'Atau pilih imej QR',
    'Camera unavailable?':'Kamera tidak tersedia?',
    'Paste the QR link':'Tampal pautan QR',
    'Continue':'Teruskan',
    'That is not an active Peekaa business QR. Ask the business to generate its latest join QR.':'Itu bukan QR perniagaan Peekaa yang aktif. Minta perniagaan menjana QR penyertaan terkini.',
    'Camera is unavailable in this browser. Choose a QR image or paste the QR link.':'Kamera tidak tersedia dalam pelayar ini. Pilih imej QR atau tampal pautan QR.',
    'Starting camera…':'Memulakan kamera…',
    'The scanner could not load. Check your connection and try again.':'Pengimbas tidak dapat dimuatkan. Semak sambungan anda dan cuba lagi.',
    'Point the camera at the business QR.':'Halakan kamera ke QR perniagaan.',
    'Camera access was not available. Choose a QR image or paste the QR link.':'Akses kamera tidak tersedia. Pilih imej QR atau tampal pautan QR.',
    'Reading QR image…':'Membaca imej QR…',
    'No active Peekaa join QR was found in that image.':'Tiada QR penyertaan Peekaa yang aktif ditemui dalam imej itu.',
    'That image could not be read. Try a clearer QR image.':'Imej itu tidak dapat dibaca. Cuba imej QR yang lebih jelas.',
    /* v295: wallet detail sections + claim flow. */
    'Transactions & points':'Transaksi & mata',
    'Recent activity':'Aktiviti terkini',
    'Full history':'Sejarah penuh',
    'Rate your visit':'Nilai lawatan anda',
    'Your latest events with this business.':'Rekod terkini anda dengan perniagaan ini.',
    'Your review helps other people find this business.':'Ulasan anda membantu orang lain menemui perniagaan ini.',
    'No purchases or points activity has been recorded for this programme yet.':'Belum ada pembelian atau aktiviti mata direkodkan untuk program ini.',
    'Every purchase, reversal, correction, and points event kept in time order.':'Setiap pembelian, pembalikan, pembetulan dan peristiwa mata disimpan mengikut susunan masa.',
    'Loyalty activity':'Aktiviti kesetiaan',
    'Your loyalty history with this business.':'Sejarah kesetiaan anda dengan perniagaan ini.',
    'Gift cards':'Kad hadiah',
    'Money left on your gift cards from this business.':'Baki wang pada kad hadiah anda daripada perniagaan ini.',
    'Show this screen at the counter — the team uses your card there. We never show the full card number.':'Tunjukkan skrin ini di kaunter — pasukan akan menggunakan kad anda di sana. Kami tidak pernah memaparkan nombor kad penuh.',
    'Packages':'Pakej',
    'Session balances and recent usage.':'Baki sesi dan penggunaan terkini.',
    'Membership':'Keahlian',
    'Current plan and period status.':'Pelan semasa dan status tempoh.',
    'Appointments':'Temu janji',
    'Upcoming and recent visits.':'Lawatan akan datang dan terkini.',
    'Your bottles':'Botol anda',
    'What {business} is keeping for you. Show this screen at the counter to have one brought out.':'Apa yang {business} simpan untuk anda. Tunjukkan skrin ini di kaunter untuk mendapatkannya.',
    'this bar':'bar ini',
    'Load more':'Muat lagi',
    'Pending with business':'Menunggu perniagaan',
    'Ready to use':'Sedia digunakan',
    'All used up':'Sudah habis digunakan',
    'Not valid':'Tidak sah',
    'This section':'Bahagian ini',
    '{section} didn’t load':'{section} tidak dimuatkan',
    'Your sign-in expired. Sign in again.':'Log masuk anda telah tamat tempoh. Sila log masuk semula.',
    'Sign in':'Log masuk',
    'Book again':'Tempah lagi',
    'Open programme':'Buka program',
    'Withdraw':'Tarik balik',
    'Waitlisted':'Dalam senarai menunggu',
    'Pending':'Menunggu',
    'Appointment':'Temu janji',
    'Add a business programme':'Tambah program perniagaan',
    'Accept invitation':'Terima jemputan',
    'Confirm this private invitation while signed in to the intended account.':'Sahkan jemputan peribadi ini semasa log masuk ke akaun yang dimaksudkan.',
    'Enter the business link from its QR or invitation. We only connect an exact unclaimed record.':'Masukkan pautan perniagaan daripada QR atau jemputannya. Kami hanya menyambungkan rekod tepat yang belum dituntut.',
    'Use the same confirmed email your business has on file.':'Gunakan e-mel disahkan yang sama seperti dalam rekod perniagaan anda.',
    'Checking access…':'Menyemak akses…',
    'How should we find your record?':'Bagaimana kami patut mencari rekod anda?',
    'Use my verified mobile number':'Guna nombor telefon bimbit saya yang disahkan',
    'Use my confirmed email instead':'Guna e-mel saya yang disahkan sebaliknya',
    'Business link':'Pautan perniagaan',
    'Claim':'Tuntut',
    'Checking…':'Menyemak…',
    'Customer access could not be checked.':'Akses pelanggan tidak dapat disemak.',
    'Customer access is unavailable. Please try again later.':'Akses pelanggan tidak tersedia. Sila cuba sebentar lagi.',
    'Choose where to continue':'Pilih tempat untuk meneruskan',
    'Wallet links:':'Pautan dompet:',
    'Staff workspaces:':'Ruang kerja kakitangan:',
    'No wallet links yet.':'Belum ada pautan dompet.',
    'Linked':'Dipautkan',
    'Request received':'Permintaan diterima',
    'Your wallet is ready.':'Dompet anda sudah sedia.',
    'If the details match an available customer record, the business link will appear here.':'Jika butiran sepadan dengan rekod pelanggan yang tersedia, pautan perniagaan akan muncul di sini.',
    'Open wallet':'Buka dompet',
    /* v295: Communications (PDPA consent) + profile consent cluster. */
    'Communications':'Komunikasi',
    'Loading your communication choices…':'Memuatkan pilihan komunikasi anda…',
    'Your communication choices could not be loaded. Nothing has been changed.':'Pilihan komunikasi anda tidak dapat dimuatkan. Tiada apa-apa yang diubah.',
    'No communication choices yet':'Belum ada pilihan komunikasi',
    'There is nothing to set here for your account right now.':'Tiada apa-apa untuk ditetapkan di sini bagi akaun anda buat masa ini.',
    'Everything is on unless you turn it off. Turning something off here never stops receipts, booking confirmations or security messages — those are not marketing and keep sending.':'Semuanya dihidupkan melainkan anda mematikannya. Mematikan sesuatu di sini tidak akan menghentikan resit, pengesahan tempahan atau mesej keselamatan — itu bukan pemasaran dan akan terus dihantar.',
    'Send me all marketing messages':'Hantar semua mesej pemasaran kepada saya',
    'One tick covers every category and every channel below — push, email, SMS, WhatsApp and calls. You can switch any single one back off at any time.':'Satu tanda meliputi setiap kategori dan setiap saluran di bawah — tolak, e-mel, SMS, WhatsApp dan panggilan. Anda boleh mematikan mana-mana satu pada bila-bila masa.',
    'Saving…':'Menyimpan…',
    'That choice could not be saved, so it has been put back. Please try again.':'Pilihan itu tidak dapat disimpan, jadi ia telah dikembalikan. Sila cuba lagi.',
    'Saved.':'Disimpan.',
    'That change could not be saved, so your choices have been put back. Please try again.':'Perubahan itu tidak dapat disimpan, jadi pilihan anda telah dikembalikan. Sila cuba lagi.',
    'All marketing messages are on.':'Semua mesej pemasaran dihidupkan.',
    'All marketing messages are off. Receipts, bookings and security messages still send.':'Semua mesej pemasaran dimatikan. Resit, tempahan dan mesej keselamatan masih dihantar.',
    'Offers from businesses you follow':'Tawaran daripada perniagaan yang anda ikuti',
    'Promotions and deals from the businesses whose programmes you have joined.':'Promosi dan tawaran daripada perniagaan yang programnya telah anda sertai.',
    'Your rewards and points':'Ganjaran dan mata anda',
    'Points you earn, rewards unlocked, and value that is about to expire.':'Mata yang anda peroleh, ganjaran yang dibuka, dan nilai yang hampir luput.',
    'Peekaa updates':'Kemas kini Peekaa',
    'News and new features from Peekaa itself.':'Berita dan ciri baharu daripada Peekaa sendiri.',
    'In-app message':'Mesej dalam apl',
    'Push notification':'Pemberitahuan tolak',
    'Email':'E-mel',
    'SMS':'SMS',
    'WhatsApp':'WhatsApp',
    'Call':'Panggilan',
    'Marketing choices':'Pilihan pemasaran',
    'Offers and updates from Nestly Technologies Pte. Ltd., the company behind {product}, and its partners, by push notification, in-app message, email, SMS, WhatsApp, phone call and other marketing channels. Your name and contact details may be shared with {product}’s partners for marketing purposes only. This is separate from messages sent by individual businesses.':'Tawaran dan kemas kini daripada Nestly Technologies Pte. Ltd., syarikat di sebalik {product}, dan rakan kongsinya, melalui pemberitahuan tolak, mesej dalam apl, e-mel, SMS, WhatsApp, panggilan telefon dan saluran pemasaran lain. Nama dan butiran hubungan anda mungkin dikongsi dengan rakan kongsi {product} untuk tujuan pemasaran sahaja. Ini berasingan daripada mesej yang dihantar oleh perniagaan individu.',
    'Yes — send me these offers and updates. I can turn this off here, or in {link}, at any time. {product} stops sending straight away. Partners are told to stop within 10 business days. Turning it off does not affect my points, bookings or service messages.':'Ya — hantar tawaran dan kemas kini ini kepada saya. Saya boleh mematikannya di sini, atau dalam {link}, pada bila-bila masa. {product} berhenti menghantar dengan serta-merta. Rakan kongsi diberitahu untuk berhenti dalam masa 10 hari bekerja. Mematikannya tidak menjejaskan mata, tempahan atau mesej perkhidmatan saya.',
    'Save marketing choice':'Simpan pilihan pemasaran',
    'Your marketing choice could not be loaded. No change has been made.':'Pilihan pemasaran anda tidak dapat dimuatkan. Tiada perubahan dibuat.',
    'Choose what you hear about and how — offers from businesses you follow, your rewards and points, and Peekaa updates.':'Pilih apa yang anda mahu dengar dan bagaimana — tawaran daripada perniagaan yang anda ikuti, ganjaran dan mata anda, dan kemas kini Peekaa.',
    'Open communications':'Buka komunikasi',
    'Your consent history':'Sejarah kebenaran anda',
    'Every marketing choice you have made, newest first. This is a record only — to change something, open Communications above.':'Setiap pilihan pemasaran yang anda buat, terbaharu dahulu. Ini rekod sahaja — untuk mengubah sesuatu, buka Komunikasi di atas.',
    'Loading your consent history…':'Memuatkan sejarah kebenaran anda…',
    /* v310 (W4b) programme stack. */
    stampsCardTitle:'Kad cop',
    pointsCardTitle:'Mata & hadiah',
    tierCardTitle:'Peringkat',
    stampsRemaining:'{count} cop lagi dan {gift} anda yang seterusnya kami belanja.',
    stampsReady:'{gift} anda sudah sedia — tunjukkan ini di kaunter.',
    stampsNoGift:'{count} cop dikumpul.',
    /* v323 (R5) — the quest. */
    stampsQuestProgress:'{filled} daripada {total} cop pada kad ini.',
    stampsQuestCarried:'{count} lagi sudah dikira untuk kad anda yang seterusnya.',
    stampsQuestClaimed:'Sudah dituntut pada kad ini',
    stampsQuestAllClaimed:'Semua hadiah pada kad ini sudah dituntut.',
    stampsQuestRetired:'Kad cop ini telah ditamatkan — tanya kami tentang baki anda.',
    pointsRemaining:'{count} lagi untuk {gift}.',
    pointsReady:'{gift} sedia untuk dituntut.',
    tierDistance:'{count} {unit} lagi ke {tier}.',
    tierTop:'Anda sudah berada di peringkat tertinggi.',
    tierUnitVisits:'lawatan',
    tierUnitPoints:'mata',
    tierUnitSpent:'perbelanjaan',
    programmePaused:'Program dijeda',
    programmePausedBody:'Tiada apa-apa sedang dikira sekarang. Apa yang anda sudah peroleh dikekalkan.',
    claimableNow:'Sedia sekarang',
    claimableCount:'{count} sedia untuk dituntut',
    showMyCode:'Tunjukkan kod saya',
    showMyCodeBody:'Tunjukkan ini kepada pasukan di kaunter.'
  }),
  ta:Object.freeze({
    home:'முகப்பு',programmes:'என் வெகுமதிகள்',rewardsTab:'வெகுமதிகள்',explore:'கண்டறிய',bookings:'முன்பதிவுகள்',scanQr:'QR ஸ்கேன்',profileTab:'சுயவிவரம்',
    notifications:'அறிவிப்புகள்',accountMenu:'கணக்கு மெனுவைத் திற',profilePasskeys:'சுயவிவரம் & கடவுச்சாவிகள்',signOut:'வெளியேறு',
    language:'மொழி',english:'English',chinese:'简体中文',backProgrammes:'என் வெகுமதிகளுக்குத் திரும்பு',
    chooseProgramme:'வெகுமதி வணிகத்தைத் தேர்ந்தெடுக்கவும்',yourProgrammes:'என் வெகுமதிகள்',
    programmesIntro:'வெகுமதிகள், சலுகைகள், முன்பதிவுகள் மற்றும் செயல்பாடுகளைத் திறக்க ஒரு வணிகத்தைத் தேர்ந்தெடுக்கவும்.',
    addProgramme:'சேர QR ஸ்கேன் செய்யவும்',openProgramme:'{business} வெகுமதிகளைத் திற',localBusiness:'உள்ளூர் வணிகம்',
    referralHeading:'{business}-க்கு நண்பரை அறிமுகப்படுத்துங்கள்',
    referralTermsWithFloor:'சேரும்போது உங்கள் குறியீட்டை நண்பர் சொல்லட்டும். அவர்கள் {floor} செலவழித்ததும், உங்களுக்கு {reward} கிடைக்கும்.',
    referralTerms:'சேரும்போது உங்கள் குறியீட்டை நண்பர் சொல்லட்டும். அவர்களின் முதல் செலவுக்குப் பிறகு, உங்களுக்கு {reward} கிடைக்கும்.',
    referralPoints:'{count} புள்ளிகள்',
    referralOnePoint:'1 புள்ளி',
    yourReferralCode:'உங்கள் பரிந்துரை குறியீடு',copyCode:'நகலெடு',shareCode:'பகிர்',codeCopied:'குறியீடு நகலெடுக்கப்பட்டது.',
    referralCodePending:'உங்கள் குறியீடு தயாராகிறது — கவுண்டரில் கேளுங்கள்.',
    referredCount:'உங்கள் மூலம் சேர்ந்து செலவழித்த நண்பர்கள்: {count}',
    shareYourCode:'உங்கள் குறியீட்டைப் பகிருங்கள்',
    referralShareMessage:'{business}-இல் என்னுடன் இணையுங்கள் — கவுண்டரில் பதிவு செய்யும்போது என் குறியீடு {code} சொல்லுங்கள்.',
    rewardReady:'வெகுமதி தயார் — மீட்டெடுக்கத் திறக்கவும்.',continueProgramme:'அடுத்து என்ன என்பதைப் பார்க்க உங்கள் வெகுமதி முகப்பைத் திறக்கவும்.',
    firstQuest:'உங்கள் முதல் வெகுமதிகள்',scanLoyaltyQr:'லாயல்டி QR-ஐ ஸ்கேன் செய்யவும்',
    firstQuestBody:'பங்கேற்கும் வணிகத்தில், கவுண்டரில் காட்டப்படும் Peekaa QR-ஐ ஸ்கேன் செய்யவும். அந்தச் சரிபார்க்கப்பட்ட வணிகமே உங்கள் முதல் வெகுமதிக் கணக்காகும்.',
    scanBusinessQr:'வணிக QR-ஐ ஸ்கேன் செய்யவும்',qrOnlyHelp:'வணிகம் வழங்கும் QR மூலம் மட்டுமே வணிகங்களைச் சேர்க்க முடியும்.',
    balance:'இருப்பு',nextReward:'அடுத்த வெகுமதி',tierProgress:'நிலை முன்னேற்றம்',benefits:'சலுகைகள் & சிறப்புரிமைகள்',
    offers:'பிறந்தநாள் & பருவகால சலுகைகள்',rewards:'வெகுமதிகள்',activityHistory:'செயல்பாடு & வரலாறு',
    noBenefits:'தற்போது கூடுதல் சிறப்புரிமைகள் எதுவும் இல்லை.',noOffers:'தற்போது பிறந்தநாள் அல்லது பருவகால சலுகைகள் இல்லை.',
    noRewards:'தற்போது வெகுமதிகள் எதுவும் இல்லை.',
    retry:'மீண்டும் முயற்சிக்கவும்',bookNow:'இப்போதே முன்பதிவு செய்யுங்கள்',requestVisit:'{business} உடன் உங்கள் அடுத்த வருகையைக் கோருங்கள்.',
    points:'புள்ளிகள்',stamps:'முத்திரைகள்',currentTier:'தற்போதைய நிலை',nextTier:'அடுத்தது: {tier}',
    terms:'விதிமுறைகள்',availableNow:'இப்போது கிடைக்கிறது',
    loadingProgramme:'வெகுமதிகள் ஏற்றப்படுகின்றன…',loadingProgrammes:'என் வெகுமதிகள் ஏற்றப்படுகின்றன…',
    successSounds:'வெற்றி ஒலிகள்',soundOff:'இயல்பாக அணைக்கப்பட்டுள்ளது',soundOn:'இயக்கத்தில்',
    soundHelp:'விருப்பத்தேர்வு. குறைந்த அசைவு கோரப்படும்போது ஒலிகள் அணைந்தே இருக்கும்.',
    merchantProgramme:'{business} வெகுமதிகள்',featured:'மெனு',
    noFeatured:'இந்த வணிகம் இன்னும் சிறப்பு அம்சங்களை வெளியிடவில்லை.',
    preferredLanguage:'விருப்ப மொழி',
    languageHelp:'{product} இந்தத் தேர்வை English, 中文, Bahasa Melayu மற்றும் தமிழில் பின்பற்றுகிறது.',
    profileSaved:'சுயவிவரம் சேமிக்கப்பட்டது.',
    'Rewards are not available for this account.':'இந்தக் கணக்கிற்கு வெகுமதிகள் கிடைக்கவில்லை.',
    'Rewards could not be loaded.':'வெகுமதிகளை ஏற்ற முடியவில்லை.',
    'Loyalty activity is not available for this account.':'இந்தக் கணக்கிற்கு லாயல்டி செயல்பாடு கிடைக்கவில்லை.',
    'Activity could not be loaded.':'செயல்பாட்டை ஏற்ற முடியவில்லை.',
    'Transaction history is not available for this account.':'இந்தக் கணக்கிற்கு பரிவர்த்தனை வரலாறு கிடைக்கவில்லை.',
    'Transaction history could not be loaded.':'பரிவர்த்தனை வரலாற்றை ஏற்ற முடியவில்லை.',
    'Gift cards are not available for this account.':'இந்தக் கணக்கிற்கு பரிசு அட்டைகள் கிடைக்கவில்லை.',
    'Gift cards could not be loaded.':'பரிசு அட்டைகளை ஏற்ற முடியவில்லை.',
    'Packages are not available for this account.':'இந்தக் கணக்கிற்கு தொகுப்புகள் கிடைக்கவில்லை.',
    'Packages could not be loaded.':'தொகுப்புகளை ஏற்ற முடியவில்லை.',
    'Membership is not available for this account.':'இந்தக் கணக்கிற்கு உறுப்பினர் நிலை கிடைக்கவில்லை.',
    'Membership could not be loaded.':'உறுப்பினர் நிலையை ஏற்ற முடியவில்லை.',
    'Appointments are not available for this account.':'இந்தக் கணக்கிற்கு சந்திப்புகள் கிடைக்கவில்லை.',
    'Appointments could not be loaded.':'சந்திப்புகளை ஏற்ற முடியவில்லை.',
    'No rewards are available right now.':'தற்போது வெகுமதிகள் எதுவும் இல்லை.',
    'No loyalty activity is available yet.':'இன்னும் லாயல்டி செயல்பாடு இல்லை.',
    'No packages are available for this account.':'இந்தக் கணக்கிற்கு தொகுப்புகள் இல்லை.',
    'No membership is available for this account.':'இந்தக் கணக்கிற்கு உறுப்பினர் நிலை இல்லை.',
    'No appointments are available yet.':'இன்னும் சந்திப்புகள் இல்லை.',
    'Scan the business QR':'வணிக QR-ஐ ஸ்கேன் செய்யவும்',
    'Use the Peekaa QR displayed by the business. A scan never joins an unrelated business.':'வணிகம் காட்டும் Peekaa QR-ஐப் பயன்படுத்தவும். ஸ்கேன் ஒருபோதும் தொடர்பில்லாத வணிகத்தில் சேர்க்காது.',
    'Close scanner':'ஸ்கேனரை மூடு',
    'Camera preview for business join QR':'வணிக சேர்க்கை QR-க்கான கேமரா முன்னோட்டம்',
    'Open camera':'கேமராவைத் திற',
    "Can't scan? Use a photo or link":'ஸ்கேன் செய்ய முடியவில்லையா? புகைப்படம் அல்லது இணைப்பைப் பயன்படுத்தவும்',
    'Or choose a QR image':'அல்லது QR படத்தைத் தேர்ந்தெடுக்கவும்',
    'Camera unavailable?':'கேமரா கிடைக்கவில்லையா?',
    'Paste the QR link':'QR இணைப்பை ஒட்டவும்',
    'Continue':'தொடரவும்',
    'That is not an active Peekaa business QR. Ask the business to generate its latest join QR.':'அது செயலில் உள்ள Peekaa வணிக QR அல்ல. சமீபத்திய சேர்க்கை QR-ஐ உருவாக்க வணிகத்திடம் கேளுங்கள்.',
    'Camera is unavailable in this browser. Choose a QR image or paste the QR link.':'இந்த உலாவியில் கேமரா கிடைக்கவில்லை. QR படத்தைத் தேர்ந்தெடுக்கவும் அல்லது QR இணைப்பை ஒட்டவும்.',
    'Starting camera…':'கேமரா தொடங்குகிறது…',
    'The scanner could not load. Check your connection and try again.':'ஸ்கேனரை ஏற்ற முடியவில்லை. உங்கள் இணைப்பைச் சரிபார்த்து மீண்டும் முயற்சிக்கவும்.',
    'Point the camera at the business QR.':'கேமராவை வணிக QR-இல் குறிவைக்கவும்.',
    'Camera access was not available. Choose a QR image or paste the QR link.':'கேமரா அணுகல் கிடைக்கவில்லை. QR படத்தைத் தேர்ந்தெடுக்கவும் அல்லது QR இணைப்பை ஒட்டவும்.',
    'Reading QR image…':'QR படம் படிக்கப்படுகிறது…',
    'No active Peekaa join QR was found in that image.':'அந்தப் படத்தில் செயலில் உள்ள Peekaa சேர்க்கை QR எதுவும் கிடைக்கவில்லை.',
    'That image could not be read. Try a clearer QR image.':'அந்தப் படத்தைப் படிக்க முடியவில்லை. தெளிவான QR படத்தை முயற்சிக்கவும்.',
    /* v295: wallet detail sections + claim flow. */
    'Transactions & points':'பரிவர்த்தனைகள் & புள்ளிகள்',
    'Recent activity':'சமீபத்திய செயல்பாடு',
    'Full history':'முழு வரலாறு',
    'Rate your visit':'உங்கள் வருகையை மதிப்பிடுங்கள்',
    'Your latest events with this business.':'இந்த வணிகத்துடனான உங்கள் சமீபத்திய பதிவுகள்.',
    'Your review helps other people find this business.':'உங்கள் மதிப்புரை மற்றவர்கள் இந்த வணிகத்தைக் கண்டறிய உதவுகிறது.',
    'No purchases or points activity has been recorded for this programme yet.':'இந்தத் திட்டத்தில் இதுவரை கொள்முதல் அல்லது புள்ளிகள் செயல்பாடு பதிவாகவில்லை.',
    'Every purchase, reversal, correction, and points event kept in time order.':'ஒவ்வொரு வாங்குதல், மாற்றியமைப்பு, திருத்தம் மற்றும் புள்ளி நிகழ்வும் கால வரிசையில் வைக்கப்படுகிறது.',
    'Loyalty activity':'லாயல்டி செயல்பாடு',
    'Your loyalty history with this business.':'இந்த வணிகத்துடனான உங்கள் லாயல்டி வரலாறு.',
    'Gift cards':'பரிசு அட்டைகள்',
    'Money left on your gift cards from this business.':'இந்த வணிகத்தின் உங்கள் பரிசு அட்டைகளில் மீதமுள்ள தொகை.',
    'Show this screen at the counter — the team uses your card there. We never show the full card number.':'இந்தத் திரையைக் கவுண்டரில் காட்டவும் — குழுவினர் அங்கு உங்கள் அட்டையைப் பயன்படுத்துவார்கள். முழு அட்டை எண்ணை நாங்கள் ஒருபோதும் காட்டுவதில்லை.',
    'Packages':'தொகுப்புகள்',
    'Session balances and recent usage.':'அமர்வு இருப்புகள் மற்றும் சமீபத்திய பயன்பாடு.',
    'Membership':'உறுப்பினர் நிலை',
    'Current plan and period status.':'தற்போதைய திட்டம் மற்றும் கால நிலை.',
    'Appointments':'சந்திப்புகள்',
    'Upcoming and recent visits.':'வரவிருக்கும் மற்றும் சமீபத்திய வருகைகள்.',
    'Your bottles':'உங்கள் பாட்டில்கள்',
    'What {business} is keeping for you. Show this screen at the counter to have one brought out.':'{business} உங்களுக்காக வைத்திருப்பவை. ஒன்றை எடுத்து வர கவுண்டரில் இந்தத் திரையைக் காட்டவும்.',
    'this bar':'இந்த பார்',
    'Load more':'மேலும் ஏற்று',
    'Pending with business':'வணிகத்தில் நிலுவையில்',
    'Ready to use':'பயன்படுத்தத் தயார்',
    'All used up':'முழுவதும் பயன்படுத்தப்பட்டது',
    'Not valid':'செல்லுபடியாகாது',
    'This section':'இந்தப் பகுதி',
    '{section} didn’t load':'{section} ஏற்றப்படவில்லை',
    'Your sign-in expired. Sign in again.':'உங்கள் உள்நுழைவு காலாவதியானது. மீண்டும் உள்நுழையவும்.',
    'Sign in':'உள்நுழை',
    'Book again':'மீண்டும் முன்பதிவு செய்',
    'Open programme':'திட்டத்தைத் திற',
    'Withdraw':'திரும்பப் பெறு',
    'Waitlisted':'காத்திருப்புப் பட்டியலில்',
    'Pending':'நிலுவையில்',
    'Appointment':'சந்திப்பு',
    'Add a business programme':'வணிகத் திட்டத்தைச் சேர்',
    'Accept invitation':'அழைப்பை ஏற்று',
    'Confirm this private invitation while signed in to the intended account.':'நோக்கப்பட்ட கணக்கில் உள்நுழைந்திருக்கும்போது இந்தத் தனிப்பட்ட அழைப்பை உறுதிப்படுத்தவும்.',
    'Enter the business link from its QR or invitation. We only connect an exact unclaimed record.':'வணிகத்தின் QR அல்லது அழைப்பிலிருந்து வணிக இணைப்பை உள்ளிடவும். சரியாகப் பொருந்தும், உரிமை கோரப்படாத பதிவை மட்டுமே இணைப்போம்.',
    'Use the same confirmed email your business has on file.':'உங்கள் வணிகத்தின் பதிவில் உள்ள அதே உறுதிப்படுத்தப்பட்ட மின்னஞ்சலைப் பயன்படுத்தவும்.',
    'Checking access…':'அணுகல் சரிபார்க்கப்படுகிறது…',
    'How should we find your record?':'உங்கள் பதிவை நாங்கள் எப்படிக் கண்டறிய வேண்டும்?',
    'Use my verified mobile number':'சரிபார்க்கப்பட்ட என் கைபேசி எண்ணைப் பயன்படுத்து',
    'Use my confirmed email instead':'அதற்குப் பதிலாக உறுதிப்படுத்தப்பட்ட என் மின்னஞ்சலைப் பயன்படுத்து',
    'Business link':'வணிக இணைப்பு',
    'Claim':'உரிமை கோர்',
    'Checking…':'சரிபார்க்கப்படுகிறது…',
    'Customer access could not be checked.':'வாடிக்கையாளர் அணுகலைச் சரிபார்க்க முடியவில்லை.',
    'Customer access is unavailable. Please try again later.':'வாடிக்கையாளர் அணுகல் கிடைக்கவில்லை. பின்னர் மீண்டும் முயற்சிக்கவும்.',
    'Choose where to continue':'எங்கே தொடர்வது என்பதைத் தேர்ந்தெடுக்கவும்',
    'Wallet links:':'வாலட் இணைப்புகள்:',
    'Staff workspaces:':'ஊழியர் பணியிடங்கள்:',
    'No wallet links yet.':'இதுவரை வாலட் இணைப்புகள் இல்லை.',
    'Linked':'இணைக்கப்பட்டது',
    'Request received':'கோரிக்கை பெறப்பட்டது',
    'Your wallet is ready.':'உங்கள் வாலட் தயார்.',
    'If the details match an available customer record, the business link will appear here.':'விவரங்கள் கிடைக்கும் வாடிக்கையாளர் பதிவுடன் பொருந்தினால், வணிக இணைப்பு இங்கே தோன்றும்.',
    'Open wallet':'வாலட்டைத் திற',
    /* v295: Communications (PDPA consent) + profile consent cluster. */
    'Communications':'தகவல் தொடர்புகள்',
    'Loading your communication choices…':'உங்கள் தகவல் தொடர்பு விருப்பங்கள் ஏற்றப்படுகின்றன…',
    'Your communication choices could not be loaded. Nothing has been changed.':'உங்கள் தகவல் தொடர்பு விருப்பங்களை ஏற்ற முடியவில்லை. எதுவும் மாற்றப்படவில்லை.',
    'No communication choices yet':'இன்னும் தகவல் தொடர்பு விருப்பங்கள் இல்லை',
    'There is nothing to set here for your account right now.':'உங்கள் கணக்கிற்கு இப்போது இங்கே அமைக்க எதுவும் இல்லை.',
    'Everything is on unless you turn it off. Turning something off here never stops receipts, booking confirmations or security messages — those are not marketing and keep sending.':'நீங்கள் அணைக்கும் வரை அனைத்தும் இயக்கத்தில் இருக்கும். இங்கே எதையேனும் அணைப்பது ரசீதுகள், முன்பதிவு உறுதிப்படுத்தல்கள் அல்லது பாதுகாப்புச் செய்திகளை நிறுத்தாது — அவை விளம்பரம் அல்ல, தொடர்ந்து அனுப்பப்படும்.',
    'Send me all marketing messages':'எனக்கு அனைத்து விளம்பரச் செய்திகளையும் அனுப்பவும்',
    'One tick covers every category and every channel below — push, email, SMS, WhatsApp and calls. You can switch any single one back off at any time.':'ஒரு தேர்வு கீழே உள்ள ஒவ்வொரு வகையையும் ஒவ்வொரு சேனலையும் உள்ளடக்கும் — புஷ், மின்னஞ்சல், SMS, WhatsApp மற்றும் அழைப்புகள். எப்போது வேண்டுமானாலும் ஒவ்வொன்றையும் தனித்தனியாக அணைக்கலாம்.',
    'Saving…':'சேமிக்கப்படுகிறது…',
    'That choice could not be saved, so it has been put back. Please try again.':'அந்தத் தேர்வைச் சேமிக்க முடியவில்லை, அது பழையபடி மாற்றப்பட்டது. மீண்டும் முயற்சிக்கவும்.',
    'Saved.':'சேமிக்கப்பட்டது.',
    'That change could not be saved, so your choices have been put back. Please try again.':'அந்த மாற்றத்தைச் சேமிக்க முடியவில்லை, உங்கள் தேர்வுகள் பழையபடி மாற்றப்பட்டன. மீண்டும் முயற்சிக்கவும்.',
    'All marketing messages are on.':'அனைத்து விளம்பரச் செய்திகளும் இயக்கத்தில் உள்ளன.',
    'All marketing messages are off. Receipts, bookings and security messages still send.':'அனைத்து விளம்பரச் செய்திகளும் அணைக்கப்பட்டுள்ளன. ரசீதுகள், முன்பதிவுகள் மற்றும் பாதுகாப்புச் செய்திகள் தொடர்ந்து அனுப்பப்படும்.',
    'Offers from businesses you follow':'நீங்கள் பின்தொடரும் வணிகங்களின் சலுகைகள்',
    'Promotions and deals from the businesses whose programmes you have joined.':'நீங்கள் சேர்ந்த திட்டங்களைக் கொண்ட வணிகங்களின் விளம்பரங்கள் மற்றும் சலுகைகள்.',
    'Your rewards and points':'உங்கள் வெகுமதிகள் மற்றும் புள்ளிகள்',
    'Points you earn, rewards unlocked, and value that is about to expire.':'நீங்கள் பெறும் புள்ளிகள், திறக்கப்பட்ட வெகுமதிகள், மற்றும் காலாவதியாகவுள்ள மதிப்பு.',
    'Peekaa updates':'Peekaa புதுப்பிப்புகள்',
    'News and new features from Peekaa itself.':'Peekaa-விலிருந்தே செய்திகள் மற்றும் புதிய அம்சங்கள்.',
    'In-app message':'செயலிக்குள் செய்தி',
    'Push notification':'புஷ் அறிவிப்பு',
    'Email':'மின்னஞ்சல்',
    'SMS':'SMS',
    'WhatsApp':'WhatsApp',
    'Call':'அழைப்பு',
    'Marketing choices':'விளம்பரத் தேர்வுகள்',
    'Offers and updates from Nestly Technologies Pte. Ltd., the company behind {product}, and its partners, by push notification, in-app message, email, SMS, WhatsApp, phone call and other marketing channels. Your name and contact details may be shared with {product}’s partners for marketing purposes only. This is separate from messages sent by individual businesses.':'{product}-ன் பின்னணி நிறுவனமான Nestly Technologies Pte. Ltd. மற்றும் அதன் கூட்டாளர்களிடமிருந்து புஷ் அறிவிப்பு, செயலிக்குள் செய்தி, மின்னஞ்சல், SMS, WhatsApp, தொலைபேசி அழைப்பு மற்றும் பிற விளம்பர சேனல்கள் வழியாக சலுகைகளும் புதுப்பிப்புகளும். உங்கள் பெயரும் தொடர்பு விவரங்களும் விளம்பர நோக்கத்திற்காக மட்டுமே {product}-ன் கூட்டாளர்களுடன் பகிரப்படலாம். இது தனிப்பட்ட வணிகங்கள் அனுப்பும் செய்திகளிலிருந்து வேறானது.',
    'Yes — send me these offers and updates. I can turn this off here, or in {link}, at any time. {product} stops sending straight away. Partners are told to stop within 10 business days. Turning it off does not affect my points, bookings or service messages.':'ஆம் — இந்தச் சலுகைகளையும் புதுப்பிப்புகளையும் எனக்கு அனுப்புங்கள். இதை இங்கே அல்லது {link} இல் எப்போது வேண்டுமானாலும் அணைக்கலாம். {product} உடனடியாக அனுப்புவதை நிறுத்தும். கூட்டாளர்கள் 10 வேலை நாட்களுக்குள் நிறுத்தச் சொல்லப்படுவார்கள். இதை அணைப்பது என் புள்ளிகள், முன்பதிவுகள் அல்லது சேவைச் செய்திகளைப் பாதிக்காது.',
    'Save marketing choice':'விளம்பரத் தேர்வைச் சேமி',
    'Your marketing choice could not be loaded. No change has been made.':'உங்கள் விளம்பரத் தேர்வை ஏற்ற முடியவில்லை. எந்த மாற்றமும் செய்யப்படவில்லை.',
    'Choose what you hear about and how — offers from businesses you follow, your rewards and points, and Peekaa updates.':'எதைப் பற்றி எப்படி அறிய வேண்டும் என்பதைத் தேர்ந்தெடுக்கவும் — நீங்கள் பின்தொடரும் வணிகங்களின் சலுகைகள், உங்கள் வெகுமதிகள் மற்றும் புள்ளிகள், மற்றும் Peekaa புதுப்பிப்புகள்.',
    'Open communications':'தகவல் தொடர்புகளைத் திற',
    'Your consent history':'உங்கள் ஒப்புதல் வரலாறு',
    'Every marketing choice you have made, newest first. This is a record only — to change something, open Communications above.':'நீங்கள் செய்த ஒவ்வொரு விளம்பரத் தேர்வும், புதியது முதலில். இது ஒரு பதிவு மட்டுமே — ஏதேனும் மாற்ற, மேலே உள்ள தகவல் தொடர்புகளைத் திறக்கவும்.',
    'Loading your consent history…':'உங்கள் ஒப்புதல் வரலாறு ஏற்றப்படுகிறது…',
    /* v310 (W4b) programme stack. */
    stampsCardTitle:'முத்திரை அட்டை',
    pointsCardTitle:'புள்ளிகள் & பரிசுகள்',
    tierCardTitle:'நிலை',
    stampsRemaining:'இன்னும் {count} முத்திரைகள், அடுத்த {gift} எங்கள் சார்பில்.',
    stampsReady:'உங்கள் {gift} தயார் — கவுண்டரில் இதைக் காட்டுங்கள்.',
    stampsNoGift:'{count} முத்திரைகள் சேர்க்கப்பட்டன.',
    /* v323 (R5) — the quest. */
    stampsQuestProgress:'இந்த அட்டையில் {total}-இல் {filled} முத்திரைகள்.',
    stampsQuestCarried:'மேலும் {count} அடுத்த அட்டைக்குக் கணக்கிடப்பட்டுள்ளன.',
    stampsQuestClaimed:'இந்த அட்டையில் பெறப்பட்டது',
    stampsQuestAllClaimed:'இந்த அட்டையின் அனைத்துப் பரிசுகளும் பெறப்பட்டன.',
    stampsQuestRetired:'இந்த முத்திரை அட்டை நிறுத்தப்பட்டது — உங்கள் இருப்பு குறித்து எங்களிடம் கேளுங்கள்.',
    pointsRemaining:'{gift} பெற இன்னும் {count} தேவை.',
    pointsReady:'{gift} பெறத் தயாராக உள்ளது.',
    tierDistance:'{tier} அடைய இன்னும் {count} {unit} தேவை.',
    tierTop:'நீங்கள் உயர்ந்த நிலையில் இருக்கிறீர்கள்.',
    tierUnitVisits:'வருகைகள்',
    tierUnitPoints:'புள்ளிகள்',
    tierUnitSpent:'செலவு',
    programmePaused:'திட்டம் இடைநிறுத்தப்பட்டுள்ளது',
    programmePausedBody:'இப்போது எதுவும் கணக்கிடப்படவில்லை. நீங்கள் ஏற்கனவே பெற்றவை பாதுகாக்கப்படும்.',
    claimableNow:'இப்போது தயார்',
    claimableCount:'{count} பெறத் தயார்',
    showMyCode:'என் குறியீட்டைக் காட்டு',
    showMyCodeBody:'கவுண்டரில் உள்ள குழுவிடம் இதைக் காட்டுங்கள்.'
  })
});
const normalizeCustomerLocale=value=>{const v=String(value||'').trim();if(v==='zh')return 'zh-CN';return CUSTOMER_LOCALES.includes(v)?v:'en'};
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
/* v329 (owner, screenshot with the Scan QR tab circled): "pressing qrcode > needs to generate
   the static qrcode (that different business able to scan and recognise this customer)". This
   modal used to open straight into the business-join camera; a customer's OWN global member QR
   (v327) had nowhere to be shown except buried in Profile. The sheet now opens on "My QR" — the
   thing another business scans to recognise this same Peekaa customer — with the join-a-business
   camera flow one tap away for the far rarer case of actually joining a new programme. */
function openCustomerJoinScanner(){
  activeCustomerJoinScannerCleanup();
  const overlay=document.createElement('div');
  overlay.className='modal customer-surface appointment-detail-modal customer-scan-modal';
  overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');
  overlay.setAttribute('aria-labelledby','customerJoinScannerTitle');
  overlay.innerHTML=`<section class="modal-card"><div class="row"><div><p class="customer-quest-kicker" id="customerScanSheetKicker">${esc(ct('My Peekaa QR'))}</p><h2 id="customerJoinScannerTitle" style="margin-top:5px">${esc(ct('My Peekaa QR'))}</h2><p class="muted small" id="customerScanSheetSubtitle" style="margin-top:5px">${esc(ct('Show this at any Peekaa business to be recognised as you.'))}</p></div><span class="spacer"></span><button class="btn ghost sm" id="customerJoinScannerClose" type="button" aria-label="${esc(ct('Close scanner'))}">${CUI.icon('close',{size:18})}</button></div>
    <div id="customerMyQrPanelV329" aria-busy="true">
      <div id="customerMyQrSlotV329" style="display:grid;place-items:center;min-height:200px;margin:16px auto;padding:12px;border:1px solid var(--line);border-radius:16px;background:#fff;max-width:240px"><p class="muted small">${esc(ct('Loading your code…'))}</p></div>
      <p id="customerMyQrStatusV329" class="muted small" role="status" aria-live="polite"></p>
      <button class="btn ghost sm" id="customerMyQrSwitchToScan" type="button" style="width:100%;margin-top:6px">${CUI.icon('scan',{size:17})}<span>${esc(ct('Scan a business QR instead'))}</span></button>
    </div>
    <div id="customerJoinScanPanelV329" hidden>
      <button class="btn ghost sm" id="customerMyQrSwitchToMine" type="button" style="width:100%;margin-bottom:12px">${CUI.icon('scan',{size:17})}<span>${esc(ct('Show my QR instead'))}</span></button>
      <p class="muted small">${esc(ct('Use the Peekaa QR displayed by the business. A scan never joins an unrelated business.'))}</p>
      <div class="scanner-frame" id="customerJoinScannerFrame" hidden><video class="scanner-video" id="customerJoinScannerVideo" playsinline muted aria-label="${esc(ct('Camera preview for business join QR'))}"></video></div>
      <button class="btn" id="customerJoinScannerCamera" type="button" style="width:100%;margin-top:16px">${CUI.icon('scan',{size:18})}<span>${esc(ct('Open camera'))}</span></button>
      <p id="customerJoinScannerStatus" class="muted small" role="status" aria-live="polite" style="margin-top:12px"></p>
      <button class="btn ghost sm" id="customerJoinScannerManual" type="button" style="width:100%;margin-top:12px">${esc(ct("Can't scan? Use a photo or link"))}</button>
      <div class="scanner-fallback" id="customerJoinScannerFallback" hidden><label for="customerJoinScannerImage">${esc(ct('Or choose a QR image'))}</label><input id="customerJoinScannerImage" type="file" accept="image/*">
        <details id="customerJoinScannerPaste" style="margin-top:12px"><summary class="small">${esc(ct('Camera unavailable?'))}</summary><label for="customerJoinScannerValue">${esc(ct('Paste the QR link'))}</label><input id="customerJoinScannerValue" type="url" autocomplete="off" spellcheck="false"><button class="btn ghost sm" id="customerJoinScannerConfirm" type="button" style="margin-top:10px">${esc(ct('Continue'))}</button></details>
      </div>
    </div></section>`;
  document.body.appendChild(overlay);
  /* This modal floats over whatever customer route is already rendered, so it must NOT share
     customerWalletRenderEpoch — bumping that global counter here would invalidate the underlying
     page's own in-flight loads. `closed` (declared below, captured by reference) is this modal's
     own lifetime signal, set the moment the sheet is dismissed. */
  void loadMemberQrIntoV327({
    card:overlay.querySelector('#customerMyQrPanelV329'),
    slot:overlay.querySelector('#customerMyQrSlotV329'),
    status:overlay.querySelector('#customerMyQrStatusV329')
  },()=>!closed);
  const myQrPanel=overlay.querySelector('#customerMyQrPanelV329');
  const scanPanel=overlay.querySelector('#customerJoinScanPanelV329');
  const kicker=overlay.querySelector('#customerScanSheetKicker');
  const subtitle=overlay.querySelector('#customerScanSheetSubtitle');
  const title=overlay.querySelector('#customerJoinScannerTitle');
  const showMyQr=()=>{
    myQrPanel.hidden=false;scanPanel.hidden=true;
    title.textContent=ct('My Peekaa QR');kicker.textContent=ct('My Peekaa QR');
    subtitle.textContent=ct('Show this at any Peekaa business to be recognised as you.');
  };
  const showScan=()=>{
    myQrPanel.hidden=true;scanPanel.hidden=false;
    title.textContent=ct('Scan the business QR');kicker.textContent=ct('addProgramme');
    subtitle.textContent=ct('Use the Peekaa QR displayed by the business. A scan never joins an unrelated business.');
    startCamera();
  };
  overlay.querySelector('#customerMyQrSwitchToScan').onclick=showScan;
  overlay.querySelector('#customerMyQrSwitchToMine').onclick=showMyQr;
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
    if(!token){status.textContent=ct('That is not an active Peekaa business QR. Ask the business to generate its latest join QR.');return false}
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
    if(!navigator.mediaDevices?.getUserMedia){status.textContent=ct('Camera is unavailable in this browser. Choose a QR image or paste the QR link.');revealFallback();return}
    camera.disabled=true;camera.hidden=true;status.textContent=ct('Starting camera…');
    if(!await loadDecoder()){
      if(closed)return;
      camera.disabled=false;camera.hidden=false;if(cameraLabel)cameraLabel.textContent=ct('retry');
      status.textContent=ct(DECODER_LOAD_FAILURE);return;
    }
    if(cameraLabel)cameraLabel.textContent=ct('Open camera');
    try{
      stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:{ideal:'environment'}},audio:false});
      if(closed){stream.getTracks().forEach(track=>track.stop());stream=null;return}
      video.srcObject=stream;frame.hidden=false;await video.play();status.textContent=ct('Point the camera at the business QR.');scan();
    }catch{
      if(closed)return;
      camera.disabled=false;camera.hidden=false;
      status.textContent=ct('Camera access was not available. Choose a QR image or paste the QR link.');revealFallback();
    }
  };
  camera.onclick=startCamera;
  manualToggle.onclick=()=>revealFallback();
  imageInput.onchange=async event=>{
    const file=event.target.files?.[0];if(!file)return;
    status.textContent=ct('Reading QR image…');
    /* v286: the photo path needs the same CDN decoder, so it reports the same honest failure
       instead of 'That image could not be read' — the image was never the problem. */
    if(!await loadDecoder()){status.textContent=ct(DECODER_LOAD_FAILURE);return}
    try{
      const bitmap=await createImageBitmap(file);
      const value=decode(bitmap,bitmap.width,bitmap.height);bitmap.close?.();
      if(!accept(value))status.textContent=ct('No active Peekaa join QR was found in that image.');
    }catch{status.textContent=ct('That image could not be read. Try a clearer QR image.')}
  };
  const pasteValue=overlay.querySelector('#customerJoinScannerValue');
  overlay.querySelector('#customerJoinScannerConfirm').onclick=()=>accept(pasteValue.value);
  /* v286 (audit): the paste field lives in no <form>, so there was no implicit submission and
     Enter — the universal reflex, and the only keyboard path — did nothing, silently. */
  pasteValue.onkeydown=event=>{if(event.key==='Enter'){event.preventDefault();accept(pasteValue.value)}};
  overlay.querySelector('#customerJoinScannerClose').onclick=close;
  overlay.addEventListener('click',event=>{if(event.target===overlay)close()});
  dialogCleanup=CUI.activateDialog(overlay,{onClose:close,initialFocus:'#customerJoinScannerClose'});
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
    ${legalLinks(customerLocale)}</section></main>`;
  if(relationshipRetry)wireCustomerRelationshipCheck(()=>route());
  CUI.focusRoute($('main'),{enhanceContent:true});
}
function customerSurfaceQualifies(profile,customerPersonas=[]){
  return (profile!==null&&profile!==undefined)||(Array.isArray(customerPersonas)&&customerPersonas.length>0);
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
    <!-- v296 (owner, annotated: "remove this — here got profile already"). The avatar menu was a
         second door to a place the navigation already owns: Profile has been a first-class tab
         since v281, so the menu's three items were one duplicate (Profile & passkeys), one
         setting that belongs beside the inbox it governs (device notifications — moved to
         Messages, where the owner drew it), and one action that belongs at the end of the page
         it acts on (Sign out — now the last thing on Profile). A header control that hides real
         actions behind a tap is exactly the pattern this navigation was rebuilt to remove. -->
    </header>${customerPrimaryNavigation(active,navCounts||customerNavCountsV194)}
    <main id="main" tabindex="-1"><div id="walletBody">${body}</div></main>
    ${legalLinks(customerLocale)}</div></div>`;
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
/* v333: `silent` is a background re-read of a surface that is ALREADY on screen and correct.
   Every failure branch below repaints the whole page with a retry card, which is the right
   answer for a first load and the wrong one for a poll — one flaky 20-second read would replace
   the customer's working wallet with an error. Silent callers get a null and the page they
   already had. */
async function loadCustomerSurfaceContext(isCurrent=()=>true,{silent=false}={}){
  const features=await loadCustomerFeatureCapabilities();
  customerInboxEnabledV178=features?.customer_in_app_inbox===true;
  if(!isCurrent())return null;
  if(features._load_error){if(!silent)renderCustomerCapabilityRetry('We could not check your customer access. Please try again.');return null}
  if(!features.customer_wallet){if(!silent)renderCustomerWalletUnavailable();return null}
  const [profileResult,personaResult]=await Promise.all([
    features.customer_phone_registration===true?customerRpc('customer_get_profile'):Promise.resolve({data:null,error:null}),
    customerRpc('get_my_personas')
  ]);
  if(!isCurrent())return null;
  let {data:personas,error:personasError}=personaResult;
  if(personasError){if(!silent)renderCustomerCapabilityRetry('We could not load your customer destinations. Please try again.');return null}
  let staff=sortStaffWorkspaces(personas?.staff||[]),customer=personas?.customer||[];
  if(profileResult.error&&!customer.length){
    if(!silent)renderCustomerCapabilityRetry('We could not load your customer profile. Please try again.');return null;
  }
  const profile=profileResult.error?null:(profileResult.data?.profile??null);
  const registeredCustomer=profile!==null;
  if(!customerSurfaceQualifies(profile,customer)){if(!silent)renderNoCustomerDestination(staff);return null}
  S.hasCustomerPersona=true;S.customerProfile=profile;
  /* v293/v294: the wallet renders in the member's stored language — all four
     of English, 中文, Bahasa Melayu and தமிழ் ('zh' folds to zh-CN). Sign-out
     resets to 'en'. */
  customerLocale=normalizeCustomerLocale(profile?.preferred_language);
  globalThis.document?.documentElement?.setAttribute('lang',customerLocale);
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

/* v327: the ONE global Peekaa member QR — one per identity, not one per business (see the
   supersession note on MEMBER_CODE_CONTRACT_W6I2 above renderCustomerQrJoin). Drawn client-side
   from the opaque token public.customer_get_member_qr_v327 returns; nothing here ever sees or
   displays the customer's phone number or an enumerable client id.
   Element-relative (no global ids inside) so both the Profile card and the Scan QR sheet's "My
   QR" panel can mount it without colliding. */
async function loadMemberQrIntoV327({card,slot,status},isCurrent){
  if(!card||!slot||!status)return;
  let {data,error}=await sb.rpc('customer_get_member_qr_v327');
  if(!isCurrent()||!card.isConnected)return;
  if(error?.code==='42501'){
    // No platform identity yet — create one (same call the claim flow makes) and retry once.
    const identity=await sb.rpc('customer_create_identity',{p_idempotency_key:crypto.randomUUID()});
    if(!isCurrent()||!card.isConnected)return;
    if(!identity.error)({data,error}=await sb.rpc('customer_get_member_qr_v327'));
    if(!isCurrent()||!card.isConnected)return;
  }
  card.removeAttribute('aria-busy');
  if(error||!data?.member_qr){
    slot.innerHTML='';
    status.innerHTML=`<span class="err">Your code could not be loaded.</span> <button class="btn ghost sm" type="button" data-member-qr-retry-v327 style="margin-left:6px">Try again</button>`;
    const retry=status.querySelector('[data-member-qr-retry-v327]');
    if(retry)retry.onclick=()=>loadMemberQrIntoV327({card,slot,status},isCurrent);
    return;
  }
  slot.innerHTML='<div data-member-qr-canvas-v327></div>';
  status.textContent='';
  void loadQrLibrary().then(()=>{
    if(!isCurrent()||!slot.isConnected)return;
    new QRCode(slot.querySelector('[data-member-qr-canvas-v327]'),
      {text:data.member_qr,width:200,height:200,correctLevel:QRCode.CorrectLevel.M});
  }).catch(()=>{
    if(isCurrent()&&slot.isConnected)slot.innerHTML='<p class="muted small">Your QR could not be drawn on this device.</p>';
  });
}
function renderCustomerWalletUnavailable(message='Customer wallet access is not available yet.'){
  setCustomerSurfaceDocumentV167();
  globalThis.document?.documentElement?.setAttribute('lang','en');
  root.innerHTML=`<div class="wallet-shell customer-surface"><div class="wallet-inner"><div class="wallet-head">
    <div class="logo">${brandWordmark()}</div><span class="spacer"></span><button class="btn ghost sm" id="walletSignOut">Sign out</button></div>
    <div class="card" style="text-align:center;padding:34px 22px"><h2>${esc(BRAND.customerLabel)} is not open yet</h2>
      <p class="muted" style="margin-top:8px">${esc(message)}</p>
    </div>${accountDeletionCardHtml()}${legalLinks(customerLocale)}</div></div>`;
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
    </div>${accountDeletionCardHtml()}${legalLinks(customerLocale)}</div></div>`;
  wireAccountDeletionButton();
  $('customerCapabilityRetry').onclick=()=>{customerFeatureCapabilities=null;route()};
  $('walletSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
}

function walletDate(value,withTime=false){
  if(!value)return '';
  const date=new Date(value);if(Number.isNaN(date.getTime()))return '';
  return date.toLocaleString('en-SG',{timeZone:'Asia/Singapore',dateStyle:'medium',...(withTime?{timeStyle:'short'}:{})});
}

function customerProgrammeLogoV95(presentation,businessName){
  return presentation.logoUrl
    ?`<img src="${esc(presentation.logoUrl)}" alt="${esc(businessName||presentation.name)} logo" loading="eager">`
    :esc(String(businessName||presentation.name||'N').trim().charAt(0).toUpperCase()||'N');
}
function customerProgrammeSwitcherMarkup(cards=[],activeSlug=''){
  if(cards.length<2)return '';
  return `<div class="customer-programme-switcher" role="navigation" aria-label="${esc(ct('chooseProgramme'))}">${cards.map(card=>{
    const business=card?.business||{};
    return `<a href="#/wallet/${encodeURIComponent(business.slug||'')}" aria-current="${business.slug===activeSlug?'true':'false'}">${esc(business.name||ct('localBusiness'))}</a>`;
  }).join('')}</div>`;
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
function customerRewardProgressMarkupV167(card){
  const reward=card?.next_eligible_reward||null,loyalty=card?.loyalty||{};
  if(!reward)return '';
  const balance=Math.max(0,Number(loyalty.balance)||0),cost=Math.max(0,Number(reward.cost_units)||0),
    unit=String(loyalty.unit||'points'),available=reward.available_now===true||cost===0,
    progress=cost>0?Math.min(100,Math.max(0,Math.round((balance/cost)*100))):100;
  return `<div class="customer-reward-progress-copy"><p class="muted small">${available?`${esc(reward.name||'Reward')} is ready to redeem.`:`${esc(customerPointTotalV103(reward.remaining_units||0))} ${esc(unit)} to ${esc(reward.name||'your next reward')}.`}</p><div class="customer-reward-progress" role="progressbar" aria-label="Progress to ${esc(reward.name||'next reward')}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${progress}" style="--reward-progress:${progress}%"><span></span></div></div>`;
}
function customerTierHasProgressV103(tier={}){
  const named=[tier.current,tier.label,tier.next].some(value=>String(value||'').trim().length>0);
  const progress=Number(tier.progress_percent);
  return named||(Number.isFinite(progress)&&progress>0);
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
  /* V299: business monogram coin, not the offer name's first letter (see home shelf). */
  const initial=(String(business?.name||item?.name||'P').trim()[0]||'P').toUpperCase();
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
function customerFeaturePriceLabelV156(item={}){
  const cents=Number(item.price_cents??item.unit_price_cents??item.default_price_cents??item.amount_cents??0);
  const currency=String(item.currency||item.currency_code||'SGD').toUpperCase();
  return Number.isFinite(cents)&&cents>0?`${currency} ${(cents/100).toFixed(2)}`:'';
}
function customerFeatureDurationLabelV156(item={}){
  const minutes=Number(item.duration_minutes??item.minutes??0);
  return Number.isFinite(minutes)&&minutes>0?`${minutes} min`:'';
}
function customerFeatureTypeLabelV156(item={}){
  const type=String(item.entity_type||item.kind||item.type||'').toLowerCase();
  if(type.includes('product'))return 'Product';
  if(type.includes('service'))return 'Service';
  return 'Available';
}
function customerFeatureCardMarkupV156(item={}){
  const image=customerMediaUrlV95(item?.image_url);
  const price=customerFeaturePriceLabelV156(item);
  const duration=customerFeatureDurationLabelV156(item);
  const label=customerFeatureTypeLabelV156(item);
  const description=String(item.description||item.tagline||'').trim();
  return `<article class="customer-reward-card customer-feature-card">
    ${image?`<img class="customer-feature-image" src="${esc(image)}" alt="" loading="lazy">`:''}
    <b>${esc(item.name||ct('featured'))}</b>
    <div class="customer-feature-meta"><span class="pill">${esc(label)}</span>${price?`<span class="pill">${esc(price)}</span>`:''}${duration?`<span class="pill">${esc(duration)}</span>`:''}</div>
    ${description?`<p class="muted small" style="margin-top:7px">${esc(description)}</p>`:''}
  </article>`;
}
function customerPointsExplainerMarkupV167(business={}){
  const key=`peekaa.customer.points-explainer.v1.${String(business.id||business.slug||'programme')}`;
  try{if(localStorage.getItem(key)==='dismissed')return ''}catch{}
  return `<aside class="card customer-points-explainer" data-points-explainer data-points-explainer-key="${esc(key)}" role="note"><p><b>How rewards work at ${esc(business.name||'this business')}</b><br><span class="muted small">Collect points here and use them for available rewards.</span></p><button class="btn ghost sm" type="button" data-points-explainer-dismiss aria-label="Dismiss points explanation">Got it</button></aside>`;
}
function customerProgrammeOffersMarkupV167({items=[],status='ready',business={},bookingEnabled=false}={}){
  let body='';
  if(status==='error')body='<div class="card customer-home-offers-state"><p class="muted small">Offers couldn’t load.</p><button class="btn ghost sm" type="button" data-programme-offers-retry>Try again</button></div>';
  else if(items.length)body=`<div class="customer-promotions-grid">${items.map(item=>customerPromotionCardV104(item,business,bookingEnabled)).join('')}</div>`;
  else body='<div class="card customer-home-offers-state"><p class="muted small">No offers right now. New offers from this business appear here first.</p></div>';
  return `<section class="customer-promotions-section" aria-labelledby="latestOffersTitle"><div class="customer-promotions-head"><div><p class="customer-quest-kicker">From ${esc(business.name||ct('localBusiness'))}</p><h2 id="latestOffersTitle">Latest offers</h2></div></div>${body}</section>`;
}
/* V174 customer tier card. One compact card, CHAGEE-style: where I am, how close the next
   tier is (exact remaining in the business's own basis — visits, spend or points), what the
   next tier unlocks (two-item teaser), then my current benefits. Renders nothing when the
   business has no tiers, and never shows raw percentages without the human sentence. */
/* v194 (owner annotations, 2026-08-07): the programme card was one long column — a tier block
   with two lines of prose above a permanently expanded ladder, and the balance stranded in the
   header. It is now two tabs, Tier and Reward points, which is what the owner sketched. The tier
   panel drops "Gold unlocks…" and "Your benefits now" (both struck out as "too many wordings"),
   names the rung plainly — "You're now at Basic" — marks every rung ON the progress bar, and
   folds the full ladder behind a disclosure that opens on tap. */
/* v195 (owner drew a star, a crown and a gem onto the rungs): the marker is positional, not a
   claim about the tier's name — first rung star, top rung gem, everything between a crown — so a
   business that calls its tiers Bronze/Silver/Gold gets the same read as one using Basic/Diamond. */
function customerTierRungIconV195(index,total){
  if(index<=0)return 'star';
  return index>=total-1?'diamond':'crown';
}
/* v333 (owner, 2026-08-15: "the UI UX is being squeezed"). Two defects, one rail.
   (1) SCALE. The markers were placed at threshold/topThreshold while the fill was drawn at
   tier.progress_percent — and progress_percent is NOT a position on that scale. The server
   computes it as (metric - current.threshold) / (next.threshold - current.threshold), i.e.
   progress THROUGH THE CURRENT SEGMENT, 0-100 every time a rung is reached. So the bar's filled
   end agreed with no marker on it: a Gold customer 57% of the way to Diamond drew a fill at 57%
   while the Gold marker sat at 34%. Both now speak one language — the RUNG INDEX.
   (2) CROWDING. Thresholds on a real ladder are near-exponential, so on the threshold scale the
   lower rungs pile onto the left of the track: at nine tiers the owner's screenshot shows four
   icons overlapping and their labels printed on top of one another. Even spacing gives every
   rung the same room whatever the business set its numbers to, and the label budget below keeps
   the text from colliding at any tier count.
   The scale is (index+1)/count, not index/(count-1): 0% is "no tier yet", which is a real state
   (metric below the first threshold — v_current is null and the server measures progress from 0),
   and it needs somewhere on the track to live. The top rung still lands exactly on 100%. */
const TIER_RAIL_LABEL_LIMIT_V333=4;
function customerTierRungsV333(tier={}){
  return (Array.isArray(tier.tiers)?tier.tiers:[]).filter(rung=>String(rung?.label||'').trim());
}
/* Past four rungs the names cannot fit side by side at 390px, so the rail carries icons alone.
   Nothing is lost: the current rung is named in the sentence above the bar, the next rung in the
   sentence below it, and every rung with its benefits in the ladder disclosure underneath. */
function customerTierRailCompactV333(tier={}){
  return customerTierRungsV333(tier).length>TIER_RAIL_LABEL_LIMIT_V333;
}
function customerTierRailProgressV333(tier={},progressPercent=0){
  /* `segmentShare`, not `within`: scripts/quality/app-surface-graph.mjs decides regex-vs-division
     from the preceding character and treats a trailing `n` as the end of `return`, so
     `within/100` reads as the start of a regex literal and the splitter loses paren depth for
     the rest of the file. */
  const segmentShare=Math.max(0,Math.min(100,Number(progressPercent)||0));
  const rungs=customerTierRungsV333(tier);
  if(rungs.length<2)return segmentShare;
  /* The server names the rung the customer is ON; `achieved` is the fallback for a payload that
     did not, and "no rung achieved yet" is the honest -1 that puts the fill in the opening
     runway rather than pretending the first tier was reached. */
  const named=rungs.findIndex(rung=>rung.current===true);
  const index=named>=0?named:rungs.filter(rung=>rung.achieved===true).length-1;
  return Math.round(Math.max(0,Math.min(100,((index+1+segmentShare/100)/rungs.length)*100))*100)/100;
}
function customerTierMilestonesMarkupV194(tier={}){
  const rungs=customerTierRungsV333(tier);
  if(rungs.length<2)return '';
  const withLabels=!customerTierRailCompactV333(tier);
  return `<div class="customer-tier-milestones" aria-hidden="true">${rungs.map((rung,index)=>{
    const at=((index+1)/rungs.length)*100;
    return `<span class="customer-tier-milestone${rung.current===true?' is-current':''}${rung.achieved===true?' is-achieved':''}" style="left:${at.toFixed(2)}%"><i>${CUI.icon(customerTierRungIconV195(index,rungs.length),{size:14})}</i>${withLabels?`<b>${esc(rung.label)}</b>`:''}</span>`;
  }).join('')}</div>`;
}
/* v310 (W4b): the two sentences this panel writes in English — the distance to the next rung and
   the top-rung line — are the Tier CARD's one sentence in the stack, and the stack ships in all
   four mandate languages. `localizeV310` swaps exactly those two for their ct() keys and changes
   nothing else; every caller on the v194 fallback path omits it and keeps the English five suites
   pin. The ladder internals below stay English this wave, by the W4 contract's own scope note. */
function customerTierUnitWordV310(basis){
  /* ct()-routed: an interpolated English unit inside a Chinese/Malay/Tamil sentence reads as
     code-switching, not localisation. The three words ship in all four locale blocks. */
  if(basis==='spend')return ct('tierUnitSpent');
  return basis==='points_earned'?ct('tierUnitPoints'):ct('tierUnitVisits');
}
function customerTierDistanceCountV310(remaining,basis){
  if(basis==='spend')return `SGD ${Number(remaining).toLocaleString('en-SG',{maximumFractionDigits:0})}`;
  return Math.ceil(remaining).toLocaleString('en-SG');
}
function customerTierPanelMarkupV194(tier={},{localizeV310=false}={}){
  const current=tier.current,next=tier.next;
  /* V230 (owner: "only 1 can be live at any go ... reflected in the customer portal"). When the
     firm redeems points for rewards, the tier ladder is not the story — showing it alongside
     "spend your points" was exactly the double narrative the owner ruled out. The reader tells
     us the firm's choice; an unchosen firm keeps today's behaviour. */
  if(String(tier.points_mode||'')==='redeem'){
    return '';
  }
  if(tier.unavailable==='not_running'){
    return `<p class="muted small">This business is not running a tier programme at the moment. Your points and rewards are unaffected.</p>`;
  }
  if(tier.unavailable==='error'){
    return `<p class="muted small">Your tier could not be checked just now. Nothing has changed — reload to try again.</p>`;
  }
  if(!current&&!next)return '<p class="muted small">This business has not set up tiers yet.</p>';
  const basis=String(tier.basis||'visits');
  const metric=Number(tier.metric||0);
  const progress=Math.max(0,Math.min(100,Number(tier.progress_percent||0)));
  const remainingText=(()=>{
    if(!next)return '';
    const remaining=Math.max(0,Number(next.threshold||0)-metric);
    if(localizeV310)return ct('tierDistance',{count:customerTierDistanceCountV310(remaining,basis),
      unit:customerTierUnitWordV310(basis),tier:next.label});
    if(basis==='spend')return `Spend SGD ${remaining.toLocaleString('en-SG',{maximumFractionDigits:0})} more to reach ${next.label}`;
    if(basis==='points_earned')return `Earn ${Math.ceil(remaining).toLocaleString('en-SG')} more points to reach ${next.label}`;
    const visits=Math.ceil(remaining);
    return `${visits.toLocaleString('en-SG')} more visit${visits===1?'':'s'} to reach ${next.label}`;
  })();
  const currentRequirement=current&&!next?customerTierRequirementTextV189(current.threshold,basis):'';
  /* V240: when a firm runs both, the customer holds two independent things — a tier they climb
     and points they spend. Saying so once here stops "will redeeming cost me my tier?".
     V258: the sentence now reads the firm's actual basis. 'points_earned' counts LIFETIME
     points earned, which redemption never reduces, so the reassurance is still true there. */
  const bothNoteV258=String(tier.points_mode||'')==='both'
    ?`<p class="muted small" style="margin-top:6px">${basis==='points_earned'?'Points you earn move you up — spending them never lowers your tier.':basis==='spend'?'What you spend moves you up. Points stay yours to spend.':'Visits move you up. Points stay yours to spend.'}</p>`:'';
  return `<p class="customer-tier-now">You're now at <b>${esc(current?.label||'Getting started')}</b>${next?'':current?' <span class="pill ok">Top tier</span>':''}</p>${bothNoteV258}
    ${next?`<div class="customer-tier-bar${customerTierRailCompactV333(tier)?' is-compact':''}"><div class="customer-tier-bar-track"><span style="width:${customerTierRailProgressV333(tier,progress)}%"></span></div>${customerTierMilestonesMarkupV194(tier)}</div>
    <p class="muted small customer-tier-remaining">${esc(remainingText)}</p>`
      :currentRequirement?`<p class="muted small customer-tier-remaining">${esc(currentRequirement)} · ${esc(localizeV310?ct('tierTop'):'you are at the highest tier.')}</p>`
        :localizeV310?`<p class="muted small customer-tier-remaining">${esc(ct('tierTop'))}</p>`:''}
    ${customerTierLadderMarkupV186(tier)}`;
}
/* v186 (owner: "i want to see different tiers and its benefits… mask other tiers, still can see
   the benefits but very obvious that is not their tier"). A ladder you cannot see is not a
   ladder — naming what the next rung unlocks is the entire reason anyone climbs. Every tier is
   listed with its own benefits; the one the SERVER placed the customer on is in full colour, the
   rest are desaturated and dimmed but fully readable, and each carries a word for its state so
   the meaning survives greyscale, colour blindness and a screen reader.
   Renders nothing for a single-tier programme, where a "ladder" would be a lie. */
function customerTierLadderMarkupV186(tier={}){
  const rungs=(Array.isArray(tier.tiers)?tier.tiers:[]).filter(rung=>String(rung?.label||'').trim());
  if(rungs.length<2)return '';
  const basis=String(tier.basis||'visits');
  const metric=Number(tier.metric||0);
  const requirement=threshold=>customerTierRequirementTextV189(threshold,basis);
  return `<details class="customer-tier-ladder">
    <summary><span>All tiers and what they unlock</span><span class="muted small">${rungs.length} tiers</span></summary>
    <ol class="customer-tier-rungs" aria-label="Every tier and what it unlocks">${rungs.map(rung=>{
      const isCurrent=rung.current===true;
      const achieved=rung.achieved===true&&!isCurrent;
      const state=isCurrent?'Your tier':achieved?'Reached':'Not yet yours';
      const benefits=(Array.isArray(rung.benefits)?rung.benefits:[]).filter(value=>String(value||'').trim());
      const remaining=Math.max(0,Number(rung.threshold||0)-metric);
      return `<li class="customer-tier-rung${isCurrent?' is-current':''}${achieved?' is-achieved':''}"${isCurrent?' aria-current="true"':''}>
        <div class="row" style="align-items:baseline;gap:8px">
          <b>${esc(rung.label)}</b>
          <span class="pill ${isCurrent?'ok':'off'}">${esc(state)}</span>
        </div>
        <p class="muted small" style="margin-top:3px">${esc(requirement(rung.threshold))}${!isCurrent&&!achieved&&remaining>0?` · ${esc(customerTierRemainingTextV186(remaining,basis))}`:''}</p>
        ${benefits.length
          ?`<ul class="rec-why" style="margin-top:6px">${benefits.map(benefit=>`<li>${esc(benefit)}</li>`).join('')}</ul>`
          :'<p class="muted small" style="margin-top:6px">Benefits not published yet.</p>'}
      </li>`;
    }).join('')}</ol>
  </details>`;
}
/* What a rung costs, in the business's own basis. Shared by the tier card header and the ladder
   so the two can never word the same threshold differently. */
function customerTierRequirementTextV189(threshold,basis){
  const value=Math.max(0,Number(threshold)||0);
  if(!value)return 'From your first visit';
  if(basis==='spend')return `From SGD ${value.toLocaleString('en-SG',{maximumFractionDigits:0})} spent`;
  if(basis==='points_earned')return `From ${value.toLocaleString('en-SG')} points earned`;
  return `From ${value.toLocaleString('en-SG')} visit${value===1?'':'s'}`;
}
function customerTierRemainingTextV186(remaining,basis){
  if(basis==='spend')return `SGD ${Number(remaining).toLocaleString('en-SG',{maximumFractionDigits:0})} to go`;
  if(basis==='points_earned')return `${Math.ceil(remaining).toLocaleString('en-SG')} points to go`;
  const visits=Math.ceil(remaining);
  return `${visits.toLocaleString('en-SG')} visit${visits===1?'':'s'} to go`;
}
/* v194: Tier and Reward points as two tabs, the shape the owner drew over the old stacked block.
   The balance moves in here from the header, where it sat beside a name it had nothing to do with. */
/* v230 (owner, looking at Cubbly: "instead of showing different points to redeem rewards - it
   should show the relevant selected model. in this case selected tier - it should reflect the
   different tiers and its benefits"): v229 makes a firm choose ONE use for points, and refuses
   redemption server-side when that choice is tiers. Cubbly had chosen tiers, and the customer was
   still being shown a point-priced catalogue with "Show QR at counter" buttons the server would
   reject. The panel is now built from the choice:
     tiers  — one panel: where you stand, what your tier gives you, and every tier above it.
     redeem — one panel: your balance and what it buys. No tier ladder for a firm not running one.
     unset  — both, as before, because nothing has been put away yet.
   The capability comes from the server (customer_portal_capabilities), so the surface and the
   redemption gate can never disagree about which one this firm runs. */
function customerProgrammeModeV230({points_mode=null,tiers=false,rewards=false}={}){
  if(points_mode==='tiers')return 'tiers';
  if(points_mode==='redeem')return 'redeem';
  return tiers&&rewards?'both':tiers?'tiers':'redeem';
}
/* v310 (W4b): `progressMarkupV310` lets the stack supply the same meter with its sentence routed
   through ct(). Omitted — which is every v194 fallback caller — the panel builds the V167 English
   line exactly as it has since v167. Nothing else about this panel changes. */
function customerProgrammePointsPanelV230({loyalty={},presentation={},reward=null,rewardsHost=false,progressMarkupV310=null}){
  const unitLabel=ct(presentation.unit);
  /* V289 (audit A3, G4). Both wallet readers return loyalty.enabled=false with EVERY number
     zeroed when the firm has the module off or its programme inactive — the server cannot
     disclose a balance for a programme that is not running. This panel printed that zero as a
     bare "0 points", which reads as "you have nothing", when what is true is "nothing is being
     counted right now, and what you already hold is kept". The tier card has said the equivalent
     since v189 (`unavailable==='not_running'`); this is the same sentence for points. Only an
     EXPLICIT false is treated as paused: an older payload with no flag keeps today's behaviour. */
  if(loyalty.enabled===false){
    return `<p class="customer-programme-paused" style="font-size:clamp(1.3rem,5vw,1.7rem);line-height:1.15;letter-spacing:-.02em"><b>Programme paused</b></p>
      <p class="muted small" style="margin-top:6px">This business isn’t running its rewards programme at the moment, so nothing is being counted. Anything you already earned is kept — it reappears here when the programme restarts.</p>`;
  }
  const balance=customerPointTotalV103(loyalty.balance??presentation.balance??0);
  const progress=progressMarkupV310??customerRewardProgressMarkupV167({loyalty,next_eligible_reward:reward});
  return `<p class="customer-programme-balance"><b>${esc(balance)}</b> <span class="muted">${esc(unitLabel)}</span></p>
    ${progress||`<p class="muted small" style="margin-top:6px">Rewards from this business appear below as you earn.</p>`}
    ${rewardsHost?'<div id="walletRewards" class="customer-programme-rewards" data-section-title="Rewards" aria-busy="true"><p class="muted small">Loading rewards…</p></div>':''}`;
}
/* In tiers mode the balance is not a wallet — it is the distance travelled — so it is stated as
   what it counts toward rather than as something to spend. */
function customerProgrammeTierPanelV230({tier={},loyalty={},presentation={}}){
  const unitLabel=ct(presentation.unit);
  const balance=customerPointTotalV103(loyalty.balance??presentation.balance??0);
  const basis=String(tier.basis||'visits');
  const counted=basis==='points_earned'
    ?`<p class="customer-programme-balance"><b>${esc(balance)}</b> <span class="muted">${esc(unitLabel)} earned</span></p>
       <p class="muted small" style="margin-top:6px">Your ${esc(unitLabel)} count toward membership here — they are not spent.</p>`
    :'';
  return `${counted}${customerTierPanelMarkupV194(tier)}`;
}
function customerProgrammeSummaryTabsV194({tier={},loyalty={},presentation={},reward=null,rewardsHost=false,capabilities={}}){
  const mode=customerProgrammeModeV230(capabilities);
  if(mode==='tiers'){
    return `<section class="card customer-programme-tabs customer-programme-single" aria-label="Your tier">
      <h2 class="customer-programme-single-head">${CUI.icon('star',{size:17})}<span>Tier</span></h2>
      ${customerProgrammeTierPanelV230({tier,loyalty,presentation})}
    </section>`;
  }
  if(mode==='redeem'){
    return `<section class="card customer-programme-tabs customer-programme-single" aria-label="Reward points">
      <h2 class="customer-programme-single-head">${CUI.icon('redeem',{size:17})}<span>Reward points</span></h2>
      ${customerProgrammePointsPanelV230({loyalty,presentation,reward,rewardsHost})}
    </section>`;
  }
  /* V299: with tiers AND spendable points, the balance sat entirely behind the unselected
     "Reward points" tab — the customer's number one fact was invisible on first paint. It now
     reads on the tab bar itself. Hidden while the programme is paused: the points panel says
     "Programme paused" there, and a bare 0 beside it would contradict that sentence. */
  const tabBalanceV299=loyalty.enabled===false?''
    :`<span class="customer-programme-tab-balance" aria-label="${esc(customerPointTotalV103(loyalty.balance??presentation.balance??0))} ${esc(ct(presentation.unit))} to spend">${esc(customerPointTotalV103(loyalty.balance??presentation.balance??0))}<small>${esc(ct(presentation.unit))}</small></span>`;
  return `<section class="card customer-programme-tabs" aria-label="Tier and reward points">
    <div class="customer-programme-tablist${tabBalanceV299?' customer-programme-tablist--with-balance':''}" role="tablist" aria-label="Tier and reward points">
      <button type="button" role="tab" id="customerProgrammeTab-tier" class="customer-programme-tab" data-programme-tab="tier" aria-selected="true" aria-controls="customerProgrammePanel" tabindex="0">${CUI.icon('star',{size:17})}<span>Tier</span></button>
      <button type="button" role="tab" id="customerProgrammeTab-points" class="customer-programme-tab" data-programme-tab="points" aria-selected="false" aria-controls="customerProgrammePanel" tabindex="-1">${CUI.icon('redeem',{size:17})}<span>Reward points</span></button>
      ${tabBalanceV299}
    </div>
    <div id="customerProgrammePanel" role="tabpanel" tabindex="0" aria-labelledby="customerProgrammeTab-tier">
      <div data-programme-panel="tier">${customerTierPanelMarkupV194(tier)}</div>
      <div data-programme-panel="points" hidden>
        ${customerProgrammePointsPanelV230({loyalty,presentation,reward,rewardsHost})}
      </div>
    </div>
  </section>`;
}
/* ===================================================================== v310 · the programme stack
   W4b. Until now a customer's programmes were TABS: one card, at most two tabs, and which tab
   existed was decided by customerProgrammeModeV230 — a mode, not the firm's actual programmes. A
   stamps firm carries points_mode='redeem' after the v306 hotfix, so it fell through to the redeem
   branch and was rendered as a card headed, hard-coded, "Reward points", printing "8 stamps"
   underneath. There were no rings anywhere in this file, and no place at all for a third or fourth
   programme.

   The stack replaces that with one card per programme the firm actually runs, in a FIXED order —
   stamps, points & gifts, tier, referral — each card carrying one figure, one sentence and one
   action or disclosure. A card renders iff the server's spine says that programme exists for this
   firm: active, or paused (which keeps its card, its retained figure and its own paused sentence —
   a programme that pauses never silently disappears). A kind the firm never ran renders nothing;
   there are no filler cards.

   THE GATE is the four-hour CDN-window contract. /app-*.js is Cloudflare-pinned for about four
   hours and chunk eviction order is not guaranteed, so for that whole window an old bundle must be
   correct against the new server AND a new bundle against the old one. `programmes` and
   `programmes_contract` arrive only from v310's customer_portal_capabilities; against anything
   older they are absent, the gate returns null, and customerProgrammeSummaryTabsV194 runs
   byte-identically to today. That same expression is the rollback path: revert the migration and
   the client falls back on its own, with no deploy. Presence alone is never treated as truth —
   both the array shape and the contract version are checked. */
const programmeStackV310=caps=>
  Array.isArray(caps?.programmes)&&caps.programmes.length>0&&caps?.programmes_contract==='v310'
    ?caps.programmes:null;
/* Fixed, regardless of which are on. v333 (owner, 2026-08-15: "shift the tier up — to the top
   of the screen, instead of points & gift"): tier leads. It is the standing that names the
   customer at this business and the one fact that does not change when they spend, so it is
   what the page should open with; stamps and points are the balance underneath it, referral is
   what they can give away. The tab fallback (customerProgrammeSummaryTabsV194) already opened
   on Tier, so this is the stack catching up to the surface it replaced rather than a second
   opinion. */
const PROGRAMME_STACK_ORDER_V310=Object.freeze(['tiers','stamps','points','referral']);
const programmeStackEntryV310=(programmes,kind)=>
  (Array.isArray(programmes)?programmes:[]).find(entry=>entry&&entry.kind===kind)||null;
/* The server answers presentation with customer_visible, and the client OBEYS it rather than
   re-deriving visibility from active alone: customer_visible is bound server-side to the SAME
   legacy capabilities the v194 tab renderer reads, so the old bundle and the new bundle cannot
   disagree about what this customer sees during the 4-hour CDN window. active without
   customer_visible is a real state (a points programme with no reward configured yet) and must
   not grow a card the tabs never showed. A paused programme keeps its card either way —
   paused_since is a never-cleared breadcrumb and the paused sentence is the honest state. */
function programmeStackCardVisibleV310(entry){
  if(!entry)return false;
  return entry.customer_visible===true||Boolean(entry.paused_since);
}
/* One paused block, used by whichever card is paused. Each card reads its OWN programmes[kind]:
   one programme pausing never blanks another card. V289 wrote this sentence for points in English;
   the stack says the same thing in all four languages, and V289's own wording stays exactly where
   it is for the fallback path. */
function customerProgrammePausedMarkupV310(entry){
  const since=String(entry?.paused_since||'').trim();
  return `<p class="customer-programme-paused" style="font-size:clamp(1.3rem,5vw,1.7rem);line-height:1.15;letter-spacing:-.02em"><b>${esc(ct('programmePaused'))}</b></p>
    <p class="muted small" style="margin-top:6px">${esc(ct('programmePausedBody'))}</p>
    ${since?`<p class="muted small customer-programme-paused-since"><time datetime="${esc(since)}">${esc(walletDate(since))}</time></p>`:''}`;
}
/* The V167 meter, with its sentence routed through ct(). V167's own English is untouched: it is
   what the fallback path renders and five suites pin it. */
function customerRewardProgressMarkupV310({loyalty={},reward=null}={}){
  if(!reward)return '';
  const balance=Math.max(0,Number(loyalty.balance)||0),cost=Math.max(0,Number(reward.cost_units)||0),
    available=reward.available_now===true||cost===0,
    progress=cost>0?Math.min(100,Math.max(0,Math.round((balance/cost)*100))):100,
    gift=String(reward.name||'').trim()||ct('rewardsTab');
  const sentence=available?ct('pointsReady',{gift})
    :ct('pointsRemaining',{count:customerPointTotalV103(reward.remaining_units||0),gift});
  return `<div class="customer-reward-progress-copy"><p class="muted small">${esc(sentence)}</p><div class="customer-reward-progress" role="progressbar" aria-label="${esc(gift)}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${progress}" style="--reward-progress:${progress}%"><span></span></div></div>`;
}
/* How many rings the card draws. N is the cost of the cheapest stamp reward we already know about
   — the server's own next_eligible_reward, which is that reward by construction. If no reward is
   known, N is UNKNOWN and the card says the plain number instead: a default of 10 would be a
   number the business never chose, printed with the authority of a picture. The card/cycle entity
   that would make N a stored fact is W6. The upper bound is a legibility limit, not a guess — past
   it the row stops being readable at 390px and the plain number is the honest figure. */
const PROGRAMME_STACK_RING_LIMIT_V310=24;
function customerStampTargetV310(reward){
  const cost=Math.floor(Number(reward?.cost_units)||0);
  return cost>0&&cost<=PROGRAMME_STACK_RING_LIMIT_V310?cost:0;
}
/* Pure CSS/SVG, no image. Filled rings are a solid fill AND a tick; empty ones a dashed outline —
   so the row survives greyscale and colour blindness exactly as the v186 ladder does. The single
   aria-label carries the whole fact; the rings themselves are decorative to a screen reader.
   prefers-reduced-motion is honoured in the stylesheet. */
function customerProgrammeStampRingsV310(collected,target){
  const total=Math.max(0,Math.floor(Number(target)||0));
  if(!total)return '';
  const filled=Math.max(0,Math.min(total,Math.floor(Number(collected)||0)));
  return `<div class="customer-programme-stamp-rings" role="img" aria-label="${esc(`${filled} of ${total} stamps collected`)}">${
    Array.from({length:total},(unused,index)=>`<span class="customer-programme-stamp-ring${index<filled?' is-filled':''}${index===total-1?' is-goal':''}" aria-hidden="true">${
      index<filled?'<svg viewBox="0 0 16 16" width="12" height="12" focusable="false"><path d="M3.2 8.6l3.1 3.1L12.8 5" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/></svg>':''}</span>`).join('')
  }</div>`;
}
/* 1 · STAMPS. Never the words "Reward points", never a raw point figure — the rings ARE the
   figure, and when N is unknown the plain count stands in. It deliberately does not use
   .customer-programme-balance: that class is the stack's single hero and belongs to the Points
   card (see the one-hero rule below). */
function customerProgrammeStampsCardV310({loyalty={},presentation={},reward=null,entry=null,rewardsHost=false}){
  const paused=entry?.active===false;
  const collected=Number(loyalty.balance??presentation.balance??0);
  const target=paused?0:customerStampTargetV310(reward);
  const rings=customerProgrammeStampRingsV310(collected,target);
  const gift=String(reward?.name||'').trim();
  const remaining=Math.max(0,Number(reward?.remaining_units??0));
  const sentence=paused?''
    :!reward?ct('stampsNoGift',{count:customerPointTotalV103(collected)})
    :(reward.available_now===true||remaining===0)?ct('stampsReady',{gift:gift||ct('rewardsTab')})
    :ct('stampsRemaining',{count:customerPointTotalV103(remaining),gift:gift||ct('rewardsTab')});
  const figure=paused?''
    :rings||`<p class="customer-programme-stamp-count"><b>${esc(customerPointTotalV103(collected))}</b> <span class="muted">${esc(ct(presentation.unit))}</span></p>`;
  return `<section class="card customer-programme-card-v310" data-programme-card="stamps" aria-label="${esc(ct('stampsCardTitle'))}">
    <h2 class="customer-programme-card-head-v310">${CUI.icon('star',{size:17})}<span>${esc(ct('stampsCardTitle'))}</span></h2>
    ${paused?customerProgrammePausedMarkupV310(entry):`${figure}
    <p class="muted small customer-programme-card-line-v310">${esc(sentence)}</p>`}
    ${rewardsHost?'<div id="walletRewards" class="customer-programme-rewards" data-section-title="Rewards" aria-busy="true"><p class="muted small">Loading rewards…</p></div>':''}
  </section>`;
}
/* 2 · POINTS & GIFTS. The one card that prints a raw point number — the stack's single hero. The
   body is customerProgrammePointsPanelV230 verbatim, with only its progress sentence localized. */
function customerProgrammePointsCardV310({loyalty={},presentation={},reward=null,entry=null,rewardsHost=false}){
  const paused=entry?.active===false||loyalty.enabled===false;
  return `<section class="card customer-programme-card-v310" data-programme-card="points" aria-label="${esc(ct('pointsCardTitle'))}">
    <h2 class="customer-programme-card-head-v310">${CUI.icon('redeem',{size:17})}<span>${esc(ct('pointsCardTitle'))}</span></h2>
    ${paused?customerProgrammePausedMarkupV310(entry)
      :customerProgrammePointsPanelV230({loyalty,presentation,reward,rewardsHost,
        progressMarkupV310:customerRewardProgressMarkupV310({loyalty,reward})})}
  </section>`;
}
/* 3 · TIER — the no-duplicate-balance rule. customerProgrammeTierPanelV230 prints
   `<p class="customer-programme-balance">{balance}</p>` labelled "{unit} earned" whenever the
   basis is points_earned. That line is NOT in the stack, and the refutation is the money
   verifier's own: 20260809_nestly_v256_tier_may_measure_lifetime_points_while_points_are_spendable
   .sql:18-26 — the tier metric is sum(points) where entry_type='earn', redemptions are a separate
   entry type and are never subtracted, so a customer who earns 5,000 and spends 4,900 keeps the
   tier the 5,000 bought and has 100 left to spend. The old panel would print 100 beside the words
   "points earned". The Tier card therefore speaks only in DISTANCE, and where a magnitude is
   unavoidable it is the server's tier.metric — never loyalty.balance, which this function is not
   even given.
   Two deliberate differences from the fallback path, both inside the stack only:
     · the points_mode==='redeem' early return is dropped — presence is decided by
       programmes['tiers'], not by a mode; the fallback path keeps it.
     · the V258 "both" reassurance is shown whenever the Points card is also present, which is
       exactly when "will redeeming cost me my tier?" is a question the customer can have. */
function customerProgrammeTierCardV310({tier={},entry=null,pointsCardPresent=false}){
  const paused=entry?.active===false;
  const tierForStack={...tier,points_mode:pointsCardPresent?'both':''};
  return `<section class="card customer-programme-card-v310" data-programme-card="tiers" aria-label="${esc(ct('tierCardTitle'))}">
    <h2 class="customer-programme-card-head-v310">${CUI.icon('star',{size:17})}<span>${esc(ct('tierCardTitle'))}</span></h2>
    ${paused?customerProgrammePausedMarkupV310(entry):customerTierPanelMarkupV194(tierForStack,{localizeV310:true})}
  </section>`;
}
/* The claimable-now strip. It fires NO new read: it is built only from facts the page already
   holds when it paints — the server's own next_eligible_reward.available_now, and a birthday
   benefit already in an actionable state. Nothing actionable renders nothing at all: an empty
   "Ready now" strip would be a promise the surface cannot keep. */
function customerClaimableFactsV310({reward=null,birthday=null}={}){
  const facts=[];
  if(reward&&reward.available_now===true)facts.push(String(reward.name||'').trim()||ct('rewardsTab'));
  /* The birthday surface's real vocabulary is ready_to_activate / available / unavailable
     (birthdayBenefitMarkup) — 'ready' is not a status this codebase emits. */
  const birthdayStatus=String(birthday?.status||'').trim();
  if(birthdayStatus==='ready_to_activate'||birthdayStatus==='available')
    facts.push(String(birthday?.label||birthday?.display||'').trim()||ct('claimableNow'));
  return facts;
}
function customerClaimableStripMarkupV310(facts){
  if(!facts.length)return '';
  return `<div class="customer-claimable-strip" id="customerClaimableStripV310" role="status">
    <span class="customer-claimable-strip-label">${CUI.icon('redeem',{size:16})}<b>${esc(ct('claimableNow'))}</b></span>
    <span class="customer-claimable-strip-count">${esc(ct('claimableCount',{count:facts.length}))}</span>
    <span class="customer-claimable-strip-items">${facts.map(fact=>`<span>${esc(fact)}</span>`).join('')}</span>
  </div>`;
}
/* W4c's landing site, shipped empty so W4c is markup and wiring only. It stays hidden and carries
   nothing: there is no member identifier on this surface yet (customer_get_profile returns
   full_name, birth_date, gender, preferred_language and nothing else) and the counter scanner
   parses exactly nestly:redemption: / nestly:growth: / nestly:promotion:, none of which is an
   identity. A QR the counter cannot scan is worse than no QR. */
function customerMemberCodeSlotMarkupV310(){
  return '<div id="customerMemberCodeSlotV310" class="customer-member-code-slot" hidden></div>';
}
function customerProgrammeStackV310({programmes=[],tier={},loyalty={},presentation={},reward=null,rewardsHost=false,birthday=null}={}){
  const entries=Object.fromEntries(PROGRAMME_STACK_ORDER_V310
    .map(kind=>[kind,programmeStackEntryV310(programmes,kind)]));
  const show=Object.fromEntries(PROGRAMME_STACK_ORDER_V310
    .map(kind=>[kind,programmeStackCardVisibleV310(entries[kind])]));
  /* The gifts host lives on whichever of the two accruing cards is present — stamps first, because
     the v308 tripwire refuses points.active AND stamps.active on one business, so at a stamps firm
     any points card in the stack is a paused one with nothing to spend. */
  const stampsHost=rewardsHost&&show.stamps&&entries.stamps?.active===true;
  /* v326 (owner: "if programme is paused/not live, remove from customer app"): the Tier card
     alone drops out entirely while its own programme is paused, rather than keeping its card
     with a "Programme paused" message. Stamps/points/referral paused behaviour is untouched —
     only Tier was annotated. */
  const tierPausedV326=entries.tiers?.active===false;
  const cards=[
    /* v333: the paint order IS PROGRAMME_STACK_ORDER_V310 — tier first. The gifts host below is
       unaffected: it is decided by which accruing card is present, never by which is on top. */
    show.tiers&&!tierPausedV326?customerProgrammeTierCardV310({tier,entry:entries.tiers,pointsCardPresent:show.points}):'',
    show.stamps?customerProgrammeStampsCardV310({loyalty,presentation,reward,entry:entries.stamps,rewardsHost:stampsHost}):'',
    show.points?customerProgrammePointsCardV310({loyalty,presentation,reward,entry:entries.points,rewardsHost:rewardsHost&&!stampsHost}):'',
    /* 4 · REFERRAL. The slot only, and unconditionally — exactly as the fallback path emits it.
       customerReferralCardMarkupV300 replaces it, and ONLY on a server {enabled:true}; any other
       answer removes it. That rule is unchanged, and deliberately NOT duplicated into the spine:
       gating the slot on programmes['referral'] too would give referral presentation two truths
       that can disagree, and the one that would lose is the card. The spine's referral row exists
       for the read path, not for this decision. */
    '<div id="walletReferralSlot" hidden></div>'
  ].filter(Boolean).join('');
  return `${customerClaimableStripMarkupV310(customerClaimableFactsV310({reward,birthday}))}
    ${customerMemberCodeSlotMarkupV310()}
    <div class="customer-programme-stack" data-programme-stack="v310">${cards}</div>`;
}
/* v337 (owner mockup "photo 1", 2026-08-15): the business-profile screen gets a plain white
   identity row (no cover photo), a red-gradient points hero directly under it, an Address/
   Call/Book now row of three tappable segments, and — only when a reward is actually
   claimable — a "reward ready" banner above the programme stack/tabs. Every figure below is
   read from the SAME actionableCard/loyalty/reward/tier data customerMerchantExperienceMarkupV95
   already has in scope; nothing here issues a new read or a new RPC. */
function customerPointsHeroVisibleV337({loyalty={},programmeCapabilities={}}={}){
  if(loyalty.enabled===false)return false;
  const stack=programmeStackV310(programmeCapabilities);
  if(stack){
    const entry=programmeStackEntryV310(stack,'points');
    return programmeStackCardVisibleV310(entry)&&entry?.active!==false;
  }
  const mode=customerProgrammeModeV230(programmeCapabilities);
  return mode==='redeem'||mode==='both';
}
/* The red "Your points" hero. Reuses customerPointTotalV103 for every figure and the same
   reward object the claimable strip and the points card already read — cost_units,
   remaining_units, available_now, name. When this firm is not running spendable points
   (tiers-only, or the points programme is paused) it renders nothing and the page falls
   back to the tier card / programme stack exactly as it did before v337. */
function customerProgrammePointsHeroMarkupV337({loyalty={},reward=null,tier={},presentation={},programmeCapabilities={}}={}){
  if(!customerPointsHeroVisibleV337({loyalty,programmeCapabilities}))return '';
  const unitLabel=ct(presentation.unit);
  const balance=Math.max(0,Number(loyalty.balance)||0);
  const cost=reward?Math.max(0,Number(reward.cost_units)||0):0;
  const progress=cost>0?Math.min(100,Math.max(0,Math.round((balance/cost)*100))):(reward?100:0);
  const fraction=reward&&cost>0?`${esc(customerPointTotalV103(balance))}/${esc(customerPointTotalV103(cost))}`:'';
  const remaining=reward?Math.max(0,Number(reward.remaining_units??Math.max(0,cost-balance))||0):0;
  const rewardName=reward?String(reward.name||'').trim()||ct('rewardsTab'):'';
  const nextLine=reward
    ?(reward.available_now===true||remaining===0
      ?`${esc(rewardName)} is ready to claim`
      :`${esc(customerPointTotalV103(remaining))} more ${esc(unitLabel)} to ${esc(rewardName)}`)
    :'';
  const currentTierLabel=String(tier.current?.label||tier.current||tier.label||'').trim();
  const tierPill=currentTierLabel?esc(tier.next?currentTierLabel:`${currentTierLabel} · Top tier`):'';
  return `<section class="card customer-points-hero-v337" aria-label="Your ${esc(unitLabel)}">
    <div class="customer-points-hero-copy-v337">
      <p class="customer-points-hero-label-v337">Your ${esc(unitLabel)}</p>
      <p class="customer-points-hero-figure-v337"><b>${esc(customerPointTotalV103(balance))}</b><span>${esc(unitLabel)}</span></p>
      ${fraction?`<p class="customer-points-hero-fraction-v337">${fraction}</p>`:''}
      ${nextLine?`<p class="customer-points-hero-next-v337">${nextLine}</p>`:''}
      <div class="customer-points-hero-bar-v337" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${progress}"><span style="width:${progress}%"></span></div>
      ${tierPill?`<span class="pill customer-points-hero-pill-v337">${tierPill}</span>`:''}
    </div>
    <span class="customer-points-hero-icon-v337" aria-hidden="true">${CUI.icon('diamond',{size:34})}</span>
  </section>`;
}
/* The "reward ready" banner. Renders only when the server's own next_eligible_reward is
   already claimable (the SAME available_now===true check customerClaimableFactsV310 uses for
   the claimable strip) — never a fabricated reward. The reward object this codebase carries
   here has only name/cost_units/remaining_units/available_now, so the banner does not print a
   description, image or validity window that is not actually in the payload. */
function customerClaimableRewardBannerMarkupV337({reward=null}={}){
  if(!reward||reward.available_now!==true)return '';
  const name=esc(String(reward.name||'').trim()||ct('rewardsTab'));
  return `<section class="card customer-claimable-banner-v337" data-claimable-banner-v337 role="status">
    <span class="customer-claimable-banner-icon-v337" aria-hidden="true">${CUI.icon('giftcard',{size:26})}</span>
    <div class="customer-claimable-banner-copy-v337">
      <p class="customer-claimable-banner-kicker-v337">You have a reward ready!</p>
      <b class="customer-claimable-banner-name-v337">${name}</b>
      <p class="muted small customer-claimable-banner-line-v337">Show this at the counter to claim it.</p>
    </div>
    <button type="button" class="btn sm customer-claimable-banner-cta-v337" data-claim-reward-scroll-v337>Claim reward ›</button>
  </section>`;
}
function customerMerchantExperienceMarkupV95({presentation,business,actionableCard,programmeCards,bookingEnabled,offersStatus='ready',rewardsHost=false,programmeCapabilities={}}){
  const loyalty=actionableCard?.loyalty||{},reward=actionableCard?.next_eligible_reward||null;
  const tier=presentation.tier||{};
  const hasTier=customerTierHasProgressV103(tier);
  const currentTierLabel=String(tier.current?.label||tier.current||tier.label||'').trim();
  const currentTierBenefits=Array.isArray(tier.current?.benefits)
    ?tier.current.benefits.filter(value=>String(value||'').trim()).map(value=>String(value).trim()):[];
  const unitLabel=ct(presentation.unit);
  const cardImage=item=>customerMediaUrlV95(item?.image_url);
  const offers=(Array.isArray(presentation.offers)?presentation.offers:[]).slice(0,6);
  /* v194 (owner: "show company details, phone number, address" beside the business name): the
     header is now the way in to the company sheet, and the booking action moved up here — "make
     it smaller and put upstair" — out of the full-width card that sat below the offers. */
  /* v326 (owner mockup: cover photo behind the logo, name and Book now; phone/address as their
     own lines beneath). presentation.heroImageUrl was already fetched (brand.hero_image_url)
     but never rendered anywhere — this is the first consumer, not a new read. Phone/address load
     inline below via the exact same customer_get_offer_business_contact_v173 call
     showCustomerBusinessDetailV178 already makes on click; the identity button and the fallback
     link both keep opening that same sheet (offers, full contact) via the existing
     [data-company-detail] wiring — nothing about that click path changed. "Other branch" from
     the mockup is left out: this surface has no branch list loaded to link to. */
  const accentV326=esc(contrastSafeBrandColor(presentation.heroColor));
  /* v327 (owner: "photo 2 - add company name" / "Company Name (missing)"): the v326 markup put
     .customer-programme-cover-v326 and .customer-programme-head-row-v326 as SIBLINGS, both
     children of the <header>. The cover div was empty — pure decoration — so the row (with its
     name text forced to color:#fff for legibility against the intended photo backdrop) landed in
     normal document flow BELOW the cover, on the plain white <header> background inherited from
     the pre-v326 base rule. White text on white: invisible, exactly what the owner saw. The row
     is now nested INSIDE the cover div so it genuinely paints over the photo/gradient, matching
     what .customer-programme-head-row-v326{position:relative;z-index:1} was already written to
     assume. Caught only by actually rendering the function with data and looking at the
     screenshot — every existing test only pattern-matches the source text, never executes it
     (see the source-regex-tests-are-vacuous lesson). */
  /* v327 (owner: "clicked tier > auto scroll to tier below"): the tier label used to be nested
     text inside the identity <button> (unclickable on its own — nesting a control inside another
     control is invalid HTML anyway). It's now a sibling button of its own, kept on the second
     line of the header so it still reads directly under the name, wired below to jump to the
     Tier card. */
  const headV327=esc(business.name||presentation.name);
  /* v337: photo 1 drops the cover-photo/gradient treatment from the identity row — it is now a
     small, plain-white row (name + logo, phone/pin affordance top-right), matching the mockup.
     The tier-jump chip and [data-company-detail] click target are unchanged. The red points
     hero and the reward-ready banner sit directly under it, before the programme stack/tabs;
     the Address/Call/Book now row moves below those, its own segment strip. */
  return `${customerProgrammeSwitcherMarkup(programmeCards,business.slug)}
    <header class="customer-programme-compact-head customer-programme-compact-head-v337" style="--merchant-accent:${accentV326}">
      <button class="customer-programme-identity" type="button" data-company-detail aria-label="Company details for ${headV327}">
        <span class="customer-programme-logo">${customerProgrammeLogoV95(presentation,business.name)}</span>
        <span class="customer-programme-compact-copy"><b>${headV327}</b></span>
      </button>
      <span class="customer-programme-head-icons-v337" aria-hidden="true">${CUI.icon('phone',{size:17})}${CUI.icon('branch',{size:17})}</span>
      ${hasTier&&currentTierLabel?`<button type="button" class="customer-programme-identity-hint customer-programme-tier-jump-v327" data-tier-scroll-v327>${esc(currentTierLabel)}</button>`:''}
    </header>
    ${customerProgrammePointsHeroMarkupV337({loyalty,reward,tier,presentation,programmeCapabilities})}
    ${customerClaimableRewardBannerMarkupV337({reward})}
    <div class="customer-programme-contact-row-v337">
      <div class="customer-programme-contact-v326" data-company-contact-inline-v326>
        <button type="button" class="customer-programme-contact-item-v337" data-company-detail>${CUI.icon('branch',{size:18})}<span>Address</span></button>
        <button type="button" class="customer-programme-contact-item-v337" data-company-detail>${CUI.icon('phone',{size:18})}<span>Call</span></button>
      </div>
      ${bookingEnabled?`<a class="btn sm customer-programme-book customer-programme-contact-item-v337 customer-programme-contact-item-book-v337" href="#/b/${encodeURIComponent(business.slug||'')}" data-repeat-booking data-business-slug="${esc(business.slug||'')}">${CUI.icon('bookings',{size:18})}<span>${esc(ct('bookNow'))}</span></a>`:''}
    </div>
    ${customerPointsExplainerMarkupV167(business)}
    ${programmeStackV310(programmeCapabilities)
      ?customerProgrammeStackV310({programmes:programmeStackV310(programmeCapabilities),tier,loyalty,presentation,reward,rewardsHost,birthday:actionableCard?.birthday_benefit||null})
      :customerProgrammeSummaryTabsV194({tier,loyalty,presentation,reward,rewardsHost,capabilities:programmeCapabilities})}
    ${customerProgrammeOffersMarkupV167({items:offers,status:offersStatus,business,bookingEnabled})}
    ${programmeStackV310(programmeCapabilities)?'':'<div id="walletReferralSlot" hidden></div>'}
    ${presentation.products.length||presentation.services.length?`<div class="customer-section-title"><h2>${esc(ct('featured'))}</h2></div><div class="customer-rewards-grid">${[...presentation.products.map(item=>({...item,entity_type:item.entity_type||'product'})),...presentation.services.map(item=>({...item,entity_type:item.entity_type||'service'}))].map(customerFeatureCardMarkupV156).join('')}</div>`:`<div class="customer-section-title"><h2>${esc(ct('featured'))}</h2></div><section class="card customer-feature-card"><p class="muted small">Featured services and products will appear here after this business publishes them.</p></section>`}
    ${presentation.benefits.length?`<div class="customer-section-title"><h2>${esc(ct('benefits'))}</h2></div><div class="customer-perks-grid">${presentation.benefits.map(item=>`<article class="customer-perk-card">${cardImage(item)?`<img src="${esc(cardImage(item))}" alt="" loading="lazy">`:''}<b>${esc(item.name||ct('benefits'))}</b>${item.tagline||item.description?`<p class="muted small" style="margin-top:5px">${esc(item.tagline||item.description)}</p>`:''}</article>`).join('')}</div>`:''}`;
}
/* v295 (owner: the counter moment — "staff records the sale, the customer is holding the phone").
   The customer surface only ever read on render, so a balance earned while the app sat open was
   invisible until the customer navigated, and a balance earned while it sat in a pocket was
   stale on return.

   Deliberately NOT a realtime socket: a customer holds no SELECT policy on points_ledger or
   credit_ledger (staff-only, by design — app.has_perm(business_id,'view_sales')), so
   postgres_changes would deliver nothing to them, and widening the ledger's read policy to feed
   a UI nicety would trade the system's most sensitive table for an animation. Refresh instead:

     * FOREGROUND — returning to the app re-reads immediately. This is the common case: the
       customer opens the app to show a QR, the sale lands, they look back.
     * WHILE WATCHING — a slow poll covers the case the app never left the foreground, and it
       stops itself. Bounded by design: paused whenever the tab is hidden (a phone left face-up
       on a counter costs nothing), and capped, because a wallet nobody is looking at must not
       poll the database until the battery dies. Any customer action re-arms it by re-rendering.

   Every tick is epoch-guarded and DOM-guarded, so a stale page can never repaint over a newer
   one — the same discipline every other async path on this surface uses. */
const CUSTOMER_WALLET_POLL_MS_V295=20000;
const CUSTOMER_WALLET_POLL_LIMIT_V295=9; // ≈3 minutes of active watching, then quiet
function watchCustomerWalletV295(isCurrent,refresh){
  activeCustomerWalletLiveCleanupV295();
  let ticks=0,timer=0,stopped=false;
  const stop=()=>{
    if(stopped)return;stopped=true;
    if(timer)clearTimeout(timer);timer=0;
    document.removeEventListener('visibilitychange',onVisibility);
    if(activeCustomerWalletLiveCleanupV295===stop)activeCustomerWalletLiveCleanupV295=()=>{};
  };
  const alive=()=>!stopped&&isCurrent()&&!!$('walletBody')?.isConnected;
  const arm=()=>{
    if(timer)clearTimeout(timer);
    if(!alive()||ticks>=CUSTOMER_WALLET_POLL_LIMIT_V295||document.visibilityState!=='visible')return;
    timer=setTimeout(async()=>{
      timer=0;
      if(!alive()||document.visibilityState!=='visible')return;
      ticks+=1;
      /* v333: the watcher re-arms ITSELF. Before, the only thing that armed the next tick was
         the full re-render the tick triggered — which is precisely the rebuild v333 removed, so
         a silent refresh would have polled once and then gone quiet. */
      try{await refresh()}catch{}
      arm();
    },CUSTOMER_WALLET_POLL_MS_V295);
  };
  async function onVisibility(){
    if(!alive())return stop();
    if(document.visibilityState!=='visible'){if(timer)clearTimeout(timer);timer=0;return}
    ticks=0;                    // back in the customer's hand: read now, and re-arm the window
    try{await refresh()}catch{}
    arm();
  }
  document.addEventListener('visibilitychange',onVisibility);
  activeCustomerWalletLiveCleanupV295=stop;
  arm();
  return {stop,rearm:arm};
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
    <p class="muted small" id="businessDemoRequestStatus" role="status" aria-live="polite" style="margin-top:8px">Peekaa records this request and a consultant will contact you. It does not create a Peekaa login.</p>
    ${legalLinks()}</section></main>`;
  CUI.focusRoute($('main'),{enhanceContent:true});
  $('businessDemoRequestBack').onclick=()=>renderBusinessSignupChoice();
  $('businessDemoRequestSubmit').onclick=async()=>{
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
    const button=$('businessDemoRequestSubmit');
    button.disabled=true;
    $('businessDemoRequestStatus').textContent='Sending your demo request…';
    try{
      const {error}=await sb.rpc('submit_demo_request_v292',{
        p_contact_name:name,p_business_name:business,p_contact_email:email,
        p_contact_phone:phone,p_sector:sector||null,p_note:notes||null
      });
      if(error)throw error;
      $('businessDemoRequestStatus').textContent='Sent. A Peekaa consultant will contact you. No account, workspace, login, Stripe Checkout or charge was created.';
    }catch(_error){
      button.disabled=false;
      $('businessDemoRequestStatus').textContent='';
      $('businessDemoRequestError').innerHTML='<div class="err">We could not send that demo request. Check your name, business name, email and mobile number, then try again.</div>';
    }
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
      $('autherr').innerHTML=`<div class="err">${esc(humanErrorV295(e,'We could not sign you in. Please try again.'))}</div>`;
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
/* v295: the workspace/portal twin of the platform console's platformErrorMessage.
   Sixteen sites rendered error.message straight into a toast or an .err block, so an owner or a
   customer could read 'Failed to fetch' or a bare Postgres code like
   'valid_promotion_reader_context_required'. Neither is copy: it cannot be translated, it names
   nothing the reader can act on, and the same failure class is already mapped and localized in
   the platform console.

   Routing the raw text through workspaceTranslationV97 alone does NOT fix it — that helper ends
   in `??source`, so an unknown string passes through verbatim. This mapper decides instead:
     1. a known provider/network string gets a real sentence;
     2. a MACHINE CODE (snake_case, or PostgREST/Postgres internals) is never shown — the reader
        gets one honest fallback;
     3. a sentence the backend deliberately wrote for a human IS shown, translated when the
        dictionary knows it.
   The raw text always goes to console.error, so debuggability is unchanged. */
const WORKSPACE_ERROR_COPY_V295=Object.freeze({
  'Failed to fetch':'We could not reach Peekaa. Check your connection and try again.',
  'NetworkError when attempting to fetch resource.':'We could not reach Peekaa. Check your connection and try again.',
  'Load failed':'We could not reach Peekaa. Check your connection and try again.',
  'The user aborted a request.':'That took too long and was stopped. Please try again.',
  'signal is aborted without reason':'That took too long and was stopped. Please try again.'
});
const PROVIDER_NOISE_V295=/^(JSON object requested|duplicate key value|new row for relation|permission denied|relation ".*" does not exist|could not find|invalid input syntax|null value in column)/i;
function humanErrorV295(error,fallback='That did not go through. Please try again.',translate=workspaceTranslationV97){
  const raw=String(error?.message??error??'').trim();
  if(raw&&globalThis.console?.error)globalThis.console.error('[peekaa] error:',raw);
  if(!raw)return translate(fallback);
  const mapped=WORKSPACE_ERROR_COPY_V295[raw];
  if(mapped)return translate(mapped);
  const machineCode=!/\s/.test(raw)||/^[a-z0-9_]+$/.test(raw)||PROVIDER_NOISE_V295.test(raw);
  return machineCode?translate(fallback):translate(raw);
}
const WORKSPACE_TEMPLATE_COPY_V97=Object.freeze({
  customerPagination:Object.freeze({en:'{total} customers · page {page} of {pages}','zh-CN':'{total} 位顾客 · 第 {page} 页，共 {pages} 页',ms:'{total} pelanggan · halaman {page} daripada {pages}'}),
  completedTransaction:Object.freeze({en:'{count} completed transaction','zh-CN':'{count} 笔已完成交易',ms:'{count} transaksi selesai'}),
  completedTransactions:Object.freeze({en:'{count} completed transactions','zh-CN':'{count} 笔已完成交易',ms:'{count} transaksi selesai'}),
  scopePeriod:Object.freeze({en:'{branch} · {from} to {to}','zh-CN':'{branch} · {from} 至 {to}',ms:'{branch} · {from} hingga {to}'}),
  allBranchesPeriod:Object.freeze({en:'All permitted branches · {from} to {to}','zh-CN':'所有获准分店 · {from} 至 {to}',ms:'Semua cawangan yang dibenarkan · {from} hingga {to}'}),
  performancePeriodRange:Object.freeze({en:'{from} to {to}','zh-CN':'{from} 至 {to}',ms:'{from} hingga {to}'}),
  /* V295: the Dashboard schedule card names the day it is showing, so the dated form is
     interpolated copy and belongs in the reviewed inventory like every other one. */
  scheduleHeadingDay:Object.freeze({en:'Schedule · {date}','zh-CN':'排程 · {date}',ms:'Jadual · {date}'}),
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
  calendarPendingRequest:Object.freeze({en:'Awaiting confirmation: {service} for {customer}, {time}, {staff}','zh-CN':'待确认：{customer} 的 {service}，{time}，{staff}',ms:'Menunggu pengesahan: {service} untuk {customer}, {time}, {staff}'}),
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
  'performancePeriodRange','scheduleHeadingDay','pointCostDerived','parkExpiryPreview','parkExpiryPreviewTier','parkKeptUntil',
  'sortByAscending','sortByDescending','bottlePercentLeft',
  'bookingRequestWaiting','bookingRequestsWaitingMany','bookingRequestsBadge',
  'staffKeptHasRecord','staffKeptHasRecords',
  'usedSessionReversedBy','preparingExport','imageCleanupPending','imageCleanupsPending',
  'positiveStampCost','positivePointsCost','switchOtherWorkspace','switchOtherWorkspaces',
  'notificationsUnread','phoneKeyDelete','phoneKeyClear','phoneKeyDigit','openCustomer',
  'removeItem','adjustLoyalty','viewAppointmentDetails','amendAppointment',
  'viewAppointmentAgenda','calendarAppointment','calendarPendingRequest','callBookingCustomer','bookAppointmentSlot','removeFromWaitlist','joinedAt',
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
  'calendarAppointment','calendarPendingRequest','bookAppointmentSlot','removeFromWaitlist','joinedAt','viewDashboardMetricDetails'
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
function relativeLuminanceHexV336(hex){
  const channels=[1,3,5].map(offset=>parseInt(hex.slice(offset,offset+2),16)/255)
    .map(channel=>channel<=.04045?channel/12.92:((channel+.055)/1.055)**2.4);
  return .2126*channels[0]+.7152*channels[1]+.0722*channels[2];
}
function hexToHslV336(hex){
  const r=parseInt(hex.slice(1,3),16)/255,g=parseInt(hex.slice(3,5),16)/255,b=parseInt(hex.slice(5,7),16)/255;
  const max=Math.max(r,g,b),min=Math.min(r,g,b);
  let h=0,s=0;const l=(max+min)/2;
  if(max!==min){
    const d=max-min;
    s=l>0.5?d/(2-max-min):d/(max+min);
    if(max===r)h=(g-b)/d+(g<b?6:0);
    else if(max===g)h=(b-r)/d+2;
    else h=(r-g)/d+4;
    h/=6;
  }
  return [h,s,l];
}
function hslToHexV336(h,s,l){
  const hue2rgb=(p,q,t)=>{
    if(t<0)t+=1;if(t>1)t-=1;
    if(t<1/6)return p+(q-p)*6*t;
    if(t<1/2)return q;
    if(t<2/3)return p+(q-p)*(2/3-t)*6;
    return p;
  };
  let r,g,b;
  if(s===0){r=g=b=l}
  else{
    const q=l<0.5?l*(1+s):l+s-l*s,p=2*l-q;
    r=hue2rgb(p,q,h+1/3);g=hue2rgb(p,q,h);b=hue2rgb(p,q,h-1/3);
  }
  const toHex=v=>Math.round(Math.max(0,Math.min(1,v))*255).toString(16).padStart(2,'0');
  return `#${toHex(r)}${toHex(g)}${toHex(b)}`.toUpperCase();
}
/* V336 (owner: "brand colour some colours are not being recognised — every company have their
   unique colour"). Before this, any chosen colour under 4.5:1 white-text contrast was silently
   swapped for the SAME fixed coral fallback — every under-contrast colour collapsed onto one
   identical header, which is the opposite of "unique colour per company" the owner wants.
   Darkening the OWNER'S OWN hue/saturation until it clears 4.5:1 keeps every company's colour
   choice visually distinct while still being legible under the white title text. */
function contrastSafeBrandColor(value){
  const fallback='#C24135';
  if(!/^#[0-9A-Fa-f]{6}$/.test(value||''))return fallback;
  const hex=value.toUpperCase();
  if(1.05/(relativeLuminanceHexV336(hex)+.05)>=4.5)return hex;
  const [h,s,l]=hexToHslV336(hex);
  for(let step=1;step<=40;step++){
    const candidate=hslToHexV336(h,s,Math.max(0,l-(l*step)/40));
    if(1.05/(relativeLuminanceHexV336(candidate)+.05)>=4.5)return candidate;
  }
  return fallback;
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

