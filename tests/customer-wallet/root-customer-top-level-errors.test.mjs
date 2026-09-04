import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
const customerUi=await readFile(new URL('../../app/customer-ui.js',import.meta.url),'utf8');
const routeSource=app.match(/async function route\(\)\{[\s\S]*?\n\}\n\n\/\* ---------- customer wallet ---------- \*\//)?.[0];
assert.ok(routeSource,'root route must be extractable');

test('customer UI helpers initialize in browser and windowless runtime contexts',()=>{
  const context={};
  vm.runInNewContext(customerUi,context);
  assert.equal(typeof context.FrenlyCustomerUI?.icon,'function');
  assert.equal(typeof context.FrenlyCustomerUI?.focusRoute,'function');
});

async function runRootRoute({
  capabilities,profileResult,hash='#/',pathname='/',sessionUser={id:'customer-root'},recoveryUserId=''
}){
  const calls={retry:[],onboard:0,profile:0,navigate:[],registration:[],auth:0,recoverySetup:0,recoveryClears:0};
  const context={
    beginRouteInvocation:()=>()=>true,
    /* route() now reads a staff-invite code from the URL before deciding where to send a
       session. These cases are all customer/recovery routing, so no invite is present; the
       stub returns none. Without it the sandbox threw ReferenceError and every case failed. */
    businessStaffInviteCodeV151:()=>'',
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
    /* Destination memory moved behind setters that touch sessionStorage; the sandbox models
       them as plain assignments so the routing assertions still observe the same state. */
    rememberPendingCustomerDestination(value){
      context.pendingCustomerDestination=context.normalizeCustomerDestination(value);
      return context.pendingCustomerDestination;
    },
    takePendingCustomerDestination(){
      const value=context.pendingCustomerDestination;
      context.pendingCustomerDestination='';
      return value;
    },
    rememberPendingCustomerBusinessSlug(value){
      context.pendingCustomerBusinessSlug=context.normalizeCustomerBusinessIntent(value);
      return context.pendingCustomerBusinessSlug;
    },
    globalThis:{NestlyPlatformConsole:null},
    dashboardRenderEpoch:0,
    customerWalletRenderEpoch:0,
    portalRenderEpoch:0,
    destroyMountedTurnstiles:()=>{},
    /* V452: route() now closes any open popover on navigation. This harness stubs everything
       that is not a routing decision (see renderPortal/nav/root above); the real function is
       exercised end-to-end in tests/browser/verify-v452-popover-dismiss.mjs step 8. */
    resetPopoverStateV452:()=>{},
    disposeCurrentRoute:()=>{},
    killCharts:()=>{},
    passwordRecoveryError:false,
    passwordRecoveryActive:false,
    /* nestly_v758: the ref-link confirmation sheet is gated on this module-level state, which
       lives outside the extracted route() body. None of these cases arrive with a ?ref= share
       code pending, so the stubs simply keep the gate closed. */
    pendingReferralSheetSlugV576:'',
    customerReferralAskedThisVisitV576:false,
    confirmCustomerShareReferralV576:async()=>true,
    clearShareReferralV576:()=>{},
    esc:value=>String(value??''),
    pendingCustomerInvitationToken:'',
    pendingCustomerBusinessSlug:'',
    pendingCustomerDestination:'',
    customerRecoveryVerified:()=>recoveryUserId,
    customerRecoveryDisposition:(recoveryUserIdValue,sessionUserId)=>{
      if(!recoveryUserIdValue)return 'none';
      return recoveryUserIdValue===sessionUserId?'require_password':'clear';
    },
    rememberCustomerRecoveryVerified:()=>{calls.recoveryClears+=1},
    renderCustomerRecoveryPasswordSetup:()=>{calls.recoverySetup+=1},
    normalizeCustomerBusinessIntent:value=>value||'',
    normalizeCustomerDestination:value=>{
      if(['#/wallet','#/customer/programmes','#/customer/bookings','#/customer/messages','#/customer/profile'].includes(value))return value;
      return /^#\/wallet\/[a-z0-9][a-z0-9-]{1,62}$/.test(value)?value:'';
    },
    history:{replaceState:()=>{}},
    location:{hash,pathname,search:''},
    entryRouteForLocation:()=>{
      const requested=String(hash||'').trim();
      if(requested&&requested!=='#'&&requested!=='#/')return requested;
      const cleanPath=(String(pathname||'/').replace(/\/+$/,'')||'/').toLowerCase();
      if(cleanPath==='/business')return '#/business';
      if(cleanPath==='/admin')return '#/platform';
      return '#/';
    },
    S:{user:null,biz:null,staffWorkspaces:[]},
    sb:{
      auth:{getSession:async()=>({data:{session:sessionUser?{user:sessionUser}:null}})},
      rpc:async name=>{
        if(name==='get_my_personas')return {data:{staff:[],customer:[],default_route:null},error:null};
        if(name==='customer_get_profile'){
          calls.profile+=1;
          return profileResult;
        }
        throw new Error(`unexpected RPC ${name}`);
      }
    },
    sortStaffWorkspaces:rows=>rows||[],
    loadCustomerFeatureCapabilities:async()=>capabilities,
    renderCustomerCapabilityRetry:message=>{calls.retry.push(message)},
    renderOnboard:()=>{calls.onboard+=1},
    nav:value=>{calls.navigate.push(value)},
    renderRecoveryInvalid:()=>{},
    renderPasswordUpdate:()=>{},
    renderPortal:()=>{},
    renderCustomerRegistration:()=>{
      calls.registration.push({
        destination:context.pendingCustomerDestination,
        business:context.pendingCustomerBusinessSlug
      });
    },
    renderEntryChoice:()=>{},
    renderAuth:()=>{calls.auth+=1},
    renderCustomerClaim:()=>{},
    renderCustomerProgrammes:()=>{},
    renderCustomerBookings:()=>{},
    /* route() writes the platform-boot and workspace-unavailable screens straight into the
       page root, which is a module-level const in app/app.js (`const root=$('root')`). The
       sandbox has no DOM, so it stands in with a sink: none of these cases reach those
       branches, and without it every case died on ReferenceError before asserting anything. */
    root:{set innerHTML(_value){},get innerHTML(){return ''},querySelector:()=>null},
    /* The v345 localhost-only customer preview is checked before any real routing decision.
       It is gated on location.hostname, so in production and here it is off — the stub returns
       false so the sandbox exercises the real routing path rather than the preview. */
    localCustomerPreviewEnabledV345:()=>false,
    /* v370 put the persona read behind a caching loader instead of calling the RPC inline. The
       sandbox already answers get_my_personas below; this routes the loader to that same answer
       so the two cannot drift apart. */
    loadPersonasV370:async()=>({data:{staff:[],customer:[],default_route:null},error:null}),
    renderCustomerMessages:()=>{},
    renderCustomerProfile:()=>{},
    renderCustomerWalletUnavailable:()=>{},
    renderCustomerWallet:()=>{},
    renderPersonaResolutionUnavailable:()=>{},
    renderPersonaChoice:()=>{},
    renderWorkspaceInactive:()=>{},
    resetClientSessionState:()=>{},
    decodeURIComponent,
    encodeURIComponent,
    URLSearchParams,
    console
  };
  const route=vm.runInNewContext(`(()=>{${routeSource};return route})()`,context);
  await route();
  return calls;
}

test('pending password recovery globally intercepts refresh and every direct customer hash',async()=>{
  for(const hash of [
    '#/wallet','#/customer/programmes','#/customer/bookings','#/customer/messages',
    '#/customer/profile','#/join','#/claim'
  ]){
    const calls=await runRootRoute({
      hash,recoveryUserId:'customer-root',
      capabilities:{_load_error:false,customer_phone_registration:true},
      profileResult:{data:null,error:null}
    });
    assert.equal(calls.recoverySetup,1,`${hash} must return to password setup`);
    assert.equal(calls.auth,0);
    assert.equal(calls.onboard,0);
  }
});

test('stale recovery marker from another user is cleared without blocking that user',async()=>{
  const calls=await runRootRoute({
    hash:'#/',recoveryUserId:'customer-a',sessionUser:{id:'customer-b'},
    capabilities:{_load_error:false,customer_phone_registration:true},
    profileResult:{data:null,error:null}
  });
  assert.equal(calls.recoveryClears,1);
  assert.equal(calls.recoverySetup,0);
  assert.equal(calls.registration.length,1);
});

test('root always opens the customer entry for a signed-in session without resolving a business workspace',async()=>{
  const calls=await runRootRoute({
    capabilities:{_load_error:true,customer_phone_registration:false},
    profileResult:{data:null,error:null}
  });
  assert.deepEqual(calls.registration,[{destination:'',business:''}]);
  assert.deepEqual(calls.retry,[]);
  assert.equal(calls.profile,0);
  assert.equal(calls.onboard,0);
  assert.deepEqual(calls.navigate,[]);
});

test('clean business path remains separate and reaches business onboarding only after authentication',async()=>{
  const calls=await runRootRoute({
    pathname:'/business',
    capabilities:{_load_error:false,customer_phone_registration:true},
    profileResult:{data:null,error:{message:'temporary profile failure'}}
  });
  assert.deepEqual(calls.registration,[]);
  assert.deepEqual(calls.retry,[]);
  assert.equal(calls.profile,0);
  assert.equal(calls.onboard,1);
  assert.deepEqual(calls.navigate,[]);
});

test('programmatic route focus suppresses the generic outline while interactive controls retain focus rings',()=>{
  const selector=':where(a,button,input,select,textarea,[tabindex]:not([tabindex="-1"])):focus-visible';
  assert.match(app,new RegExp(selector.replaceAll(/[.*+?^${}()|[\]\\]/g,'\\$&')+'\\{outline:3px solid var\\(--coral\\);outline-offset:3px\\}'));
  assert.match(app,/:where\(main,h1,h2,h3\)\[tabindex="-1"\]:focus\{outline:none\}/,
    'programmatically focused route landmarks and headings must suppress the browser default outline');
  assert.doesNotMatch(app,/:where\([^)]*,\[tabindex\]\):focus-visible/,
    'the generic focus rule must not target route headings and landmarks with tabindex=-1');
  const resetTargets=app.match(/:where\(([^)]*)\)\[tabindex="-1"\]:focus\{outline:none\}/)?.[1].split(',');
  assert.deepEqual(resetTargets,['main','h1','h2','h3'],
    'the reset must remain limited to non-interactive route landmarks and headings');
  for(const control of ['a','button','input','select','textarea']){
    assert.ok(selector.includes(control),`${control} must keep its visible keyboard focus ring`);
  }
});

test('unauthenticated customer deep links keep their destination and never fall into business sign in',async()=>{
  for(const [hash,destination,business] of [
    ['#/wallet','#/wallet',''],
    ['#/wallet/kopi-tiam','#/wallet/kopi-tiam','kopi-tiam'],
    ['#/customer/programmes','#/customer/programmes',''],
    ['#/customer/bookings','#/customer/bookings',''],
    ['#/customer/messages','#/customer/messages',''],
    ['#/customer/profile','#/customer/profile','']
  ]){
    const calls=await runRootRoute({hash,sessionUser:null,capabilities:null,profileResult:null});
    assert.deepEqual(calls.registration,[{destination,business}],`${hash} must open mobile customer verification`);
    assert.equal(calls.auth,0,`${hash} must not open business email/password sign in`);
  }

  for(const hash of ['#/business','#/workspace/kopi-tiam/dashboard']){
    const calls=await runRootRoute({hash,sessionUser:null,capabilities:null,profileResult:null});
    assert.deepEqual(calls.registration,[],`${hash} must remain outside the customer auth flow`);
    assert.equal(calls.auth,1,`${hash} must retain the business auth flow`);
  }

  const cleanBusiness=await runRootRoute({
    pathname:'/business',hash:'',sessionUser:null,capabilities:null,profileResult:null
  });
  assert.deepEqual(cleanBusiness.registration,[]);
  assert.equal(cleanBusiness.auth,1,'/business must open the business auth flow');

  const deepCustomer=await runRootRoute({
    pathname:'/business',hash:'#/wallet/kopi-tiam',sessionUser:null,capabilities:null,profileResult:null
  });
  assert.deepEqual(deepCustomer.registration,[{destination:'#/wallet/kopi-tiam',business:'kopi-tiam'}],
    'an explicit customer deep link must override the clean business entry path');
  assert.equal(deepCustomer.auth,0);
});
