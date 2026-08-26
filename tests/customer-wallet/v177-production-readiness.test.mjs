import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const section=(source,start,end)=>{
  const from=source.indexOf(start),to=source.indexOf(end,from);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return source.slice(from,to);
};

const [app,customerUi,sw,manifest,supabaseConfig]=await Promise.all([
  Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n')),
  read('app/customer-ui.js'),
  read('app/sw.js'),
  read('app/manifest.webmanifest'),
  read('supabase/config.toml')
]);

test('uncaught browser errors reach the v177 intake instead of dying silently',()=>{
  assert.match(app,/window\.addEventListener\('error',reportClientError\)/);
  assert.match(app,/window\.addEventListener\('unhandledrejection',reportClientError\)/);

  const reporter=section(app,'function reportClientError(','const customerRpcSignal=');
  assert.match(reporter,/sb\.rpc\('report_client_error_v177',\{/,'the production RPC must be the sink');
  assert.match(reporter,/\}\)\)\.catch\(\(\)=>\{\}\)/,'reporting failure must be swallowed, never surfaced');
  assert.match(reporter,/p_surface:clientErrorSurface\(\)/);
  assert.match(reporter,/\.slice\(0,500\)/,'message must respect the 500-char server cap');
  assert.match(reporter,/\.slice\(0,2000\)/,'stack must respect the 2000-char server cap');
  assert.match(reporter,/\.slice\(0,300\)/,'url must respect the 300-char server cap');
});

test('the browser caps and dedupes its own reports so one loop cannot flood the table',()=>{
  assert.match(app,/const CLIENT_ERROR_REPORT_LIMIT=5;/);
  assert.match(app,/const clientErrorReportSeen=new Set\(\);/);
  const reporter=section(app,'function reportClientError(','const customerRpcSignal=');
  assert.match(reporter,/if\(clientErrorReportCount>=CLIENT_ERROR_REPORT_LIMIT\)return;/);
  assert.match(reporter,/if\(clientErrorReportSeen\.has\(message\)\)return;/);

  const noise=section(app,'const clientErrorIsNoise=','function clientErrorSurface(');
  assert.match(noise,/ResizeObserver loop/);
  assert.match(noise,/Script error\.'\)&&!stack/,'a stackless cross-origin script error carries nothing actionable');
  assert.match(noise,/AbortError/,'our own timeouts and navigations must not be reported as faults');
});

test('the reported surface never mislabels a business route as a customer one',()=>{
  const surface=section(app,'function clientErrorSurface(','function reportClientError(');
  assert.match(surface,/#\/business/);
  assert.match(surface,/#\/platform/);
  assert.match(surface,/return 'business'/);
  assert.match(surface,/return 'customer'/);
  assert.match(surface,/return 'public'/);
  assert.match(surface,/try\{if\(typeof S!=='undefined'/,'S is a TDZ binding early in load and must be probed defensively');
});

test('customer reads carry a deadline and fail into the existing retry branches',()=>{
  assert.match(app,/const customerRpc=\(name,args,ms=12000\)=>sb\.rpc\(name,args\)\.abortSignal\(customerRpcSignal\(ms\)\)/);
  assert.match(app,/\.then\(result=>result,error=>\(\{data:null,error:\{code:'timeout'/,
    'an abort must resolve into the destructured {data,error} shape, not reject');
  const signal=section(app,'const customerRpcSignal=','const customerRpc=');
  assert.match(signal,/AbortSignal\?\.timeout==='function'/);
  assert.match(signal,/new AbortController\(\)/,'older webviews still need the controller fallback');
});

test('every hangable customer read path is routed through the timeout helper',()=>{
  const context=section(app,'async function loadCustomerSurfaceContext(','async function renderCustomerProgrammes(');
  assert.match(context,/customerRpc\('customer_get_profile'\)/);
  /* V370: personas is shared with the workspace surface through loadPersonasV370, which takes
     `abortable` precisely so the customer side keeps the v177 timeout. The invariant is the same
     one — no unbounded call in this gate — so it is asserted at the helper as well. */
  assert.match(context,/loadPersonasV370\(\{abortable:true\}\)/);
  assert.doesNotMatch(context,/sb\.rpc\(/,'the surface context gate must not keep an unbounded call');
  const personaHelper=section(app,'async function loadPersonasV370(','async function loadBusinessControlV370(');
  assert.match(personaHelper,/abortable\?await customerRpc\('get_my_personas'\)/,
    'the shared persona loader must still use the timeout helper on the customer surface');

  const join=section(app,'async function renderCustomerQrJoin(','async function renderCustomerClaim(');
  assert.match(join,/customerRpc\('customer_join_business_from_qr_v89'/);

  const wallet=section(app,'async function renderCustomerWallet(businessSlug=null,{silent=false,forceV498=false}={}){','const loadGrowthOffers=');
  for(const name of ['customer_get_wallet','customer_get_actionable_wallet','customer_get_home_offers_v167',
    'customer_get_booking_requests','customer_get_programme_selector_media_v96',
    'customer_get_business_summary','customer_portal_capabilities']){
    assert.match(wallet,new RegExp(`customerRpc\\('${name}'`),`${name} must carry a deadline`);
    assert.doesNotMatch(wallet,new RegExp(`sb\\.rpc\\('${name}'`),`${name} must have no unbounded call left`);
  }

  const loaders=section(app,'const loadRewards=async()=>{','const slotCurrent=');
  for(const name of ['customer_get_reward_catalog','customer_get_loyalty_details',
    'customer_get_transaction_history_v167','customer_get_gift_cards','customer_get_packages',
    'customer_get_memberships','customer_get_appointments_page']){
    assert.match(loaders,new RegExp(`customerRpc\\('${name}'`),`${name} must carry a deadline`);
  }

  const empty=section(app,'async function walletSectionEmpty(','function customerProgrammePresentationV95');
  assert.match(empty,/customerRpc\('customer_portal_capabilities'/);
});

test('Android Back closes a customer dialog without leaving the route',()=>{
  const activate=section(customerUi,'function activateDialog(','function setButtonBusy(');
  assert.match(activate,/if\(!inherited\)history\.pushState\(\{\.\.\.\(history\.state\|\|\{\}\),cuiDialog:historyId\},''\)/,
    'the pushed entry must keep the same URL so hashchange never fires');
  assert.match(activate,/window\.addEventListener\('popstate',popstate\)/);
  assert.match(activate,/window\.removeEventListener\('popstate',popstate\)/);
  assert.match(activate,/if\(closedByUs\|\|!dialog\.isConnected\)return;\s*onClose\?\.\(\)/,
    'Back must take the same close path as Escape');
  assert.match(activate,/if\(!closedByUs&&history\.state\?\.cuiDialog===historyId\)\{closedByUs=true;try\{history\.back\(\)\}catch\{\}\}/,
    'our own entry is unwound exactly once');
  assert.match(app,/window\.addEventListener\('hashchange',route\)/);
  assert.doesNotMatch(app,/addEventListener\('popstate',route\)/,
    'the router must stay hashchange-only or the dialog entry would re-render the route');
});

test('the merchant accent can never render unreadable customer copy',()=>{
  assert.match(app,/const heroColor=contrastSafeBrandColor\(/);
  /* v326: the header now composes --merchant-accent through accentV326=esc(contrastSafeBrandColor(...))
     instead of inlining the call at the style attribute — same guard, one level of indirection. */
  assert.match(app,/const accentV326=esc\(contrastSafeBrandColor\(presentation\.heroColor\)\);/);
  assert.match(app,/--merchant-accent:\$\{accentV326\}/);
  assert.match(app,/const accent=contrastSafeBrandColor\(/);
  assert.ok(app.indexOf('function contrastSafeBrandColor(')>=0,'the guard must exist');
});

test('customer decisions use the in-app dialog, never a native prompt or confirm',()=>{
  const dialog=section(app,'function showCustomerDecisionDialog(','function showPendingRedemptionQr(');
  assert.match(dialog,/input=null\}=\{\}\)/);
  assert.match(dialog,/const cancelValue=\(\)=>input\?null:false;/,'prompt-mode cancel must be null, not false');
  assert.match(dialog,/const confirmValue=\(\)=>input\?String\(field\?\.value\?\?''\):true;/);
  assert.match(dialog,/initialFocus:input\?'#customerDecisionInput':'#customerDecisionKeep'/);

  const passkeys=section(app,"passkeyList.querySelectorAll('[data-passkey-rename]')","passkeyList.querySelectorAll('[data-passkey-delete]')");
  assert.doesNotMatch(passkeys,/\bprompt\(/,'passkey rename must not fall back to a native prompt');
  assert.match(passkeys,/await showCustomerDecisionDialog\(\{/);
  assert.match(passkeys,/if\(friendlyName===null\)/,'cancel must stay a no-op');
  assert.match(passkeys,/name\.length>120/,'the existing validation must be unchanged');

  const cancelBooking=section(app,'const mCancelHandler=async()=>{','const mRescheduleHandler=async()=>{');
  assert.doesNotMatch(cancelBooking,/\bconfirm\(/,'public booking cancel must not use a native confirm');
  assert.match(cancelBooking,/showCustomerDecisionDialog\(\{title:'Cancel this booking\?'/);
  assert.match(cancelBooking,/if\(!confirmed\) return;/);
});

test('the service worker ships the v177 shell and keeps navigation network-first',()=>{
  // v195 moved the shell to v9 so the un-fingerprinted customer-ui.js (two new icons) is refetched.
  // V289 moves it to v10: the install no longer calls skipWaiting and the app document itself is
  // precached, so every client must build the new cache rather than inherit the old one.
  assert.match(sw,/const CACHE_VERSION='v20-20260826-css1';/);
  const fetchHandler=section(sw,"self.addEventListener('fetch'",'const CUSTOMER_PUSH_TYPES=');
  assert.match(fetchHandler,/if\(request\.mode==='navigate'\)\{/);
  assert.match(fetchHandler,/return await fetch\(request\)/,'navigation must try the network first');
  assert.match(fetchHandler,/cache\.match\('\/offline\.html'\)/,'a failed navigation must land on the offline fallback');
  assert.match(sw,/SENSITIVE_PREFIXES=Object\.freeze\(\[\s*'\/api\/','\/auth\/','\/rest\/','\/rpc\/','\/storage\/','\/functions\/'/);
});

test('the install manifest declares a real maskable icon separate from the square one',()=>{
  const parsed=JSON.parse(manifest);
  const maskable=parsed.icons.filter(icon=>String(icon.purpose||'').split(/\s+/).includes('maskable'));
  assert.equal(maskable.length,1,'exactly one padded maskable source');
  assert.equal(maskable[0].src,'/icons/peekaa-512-maskable.png');
  assert.equal(maskable[0].sizes,'512x512');
  const any=parsed.icons.filter(icon=>icon.purpose==='any');
  assert.deepEqual(any.map(icon=>icon.src),['/icons/peekaa-192.png','/icons/peekaa-512.png'],
    'the unpadded icons must no longer claim to be maskable — Android would crop into the logo');
});

test('config.toml warns that hosted-only auth protections are not represented here',()=>{
  const header=supabaseConfig.slice(0,supabaseConfig.indexOf('[auth]'));
  assert.match(header,/production auth protections \(CAPTCHA\/Turnstile secret, leaked-password protection\)/);
  assert.match(header,/Never `supabase config push`[\s\S]{0,8}this file against gadpooereceldfpfxsod/);
});
