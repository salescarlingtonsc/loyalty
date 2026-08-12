import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const repoRoot=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const join=await readFile(path.join(repoRoot,'app/join.html'),'utf8');
const app=((await readFile(path.join(repoRoot,'app/index.html'),'utf8'))+'\n'+(await readFile(path.join(repoRoot,'app/app.js'),'utf8')));
const brand=await readFile(path.join(repoRoot,'app/brand-config.js'),'utf8');

function extractedCustomerHandoffUrl(){
  const source=join.match(/function customerHandoffUrl\(joinToken,currentUrl=location\.href\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(source,'join page must expose its customer handoff URL builder');
  return vm.runInNewContext(`(${source})`,{URL,encodeURIComponent});
}

function extractedBusinessIntentNormalizer(){
  const source=app.match(/function normalizeCustomerBusinessIntent\(value,currentUrl=location\.href\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(source,'SPA must expose its customer business-intent normalizer');
  return vm.runInNewContext(`(${source})`,{URL,URLSearchParams,decodeURIComponent});
}

function extractedDestinationPriority(){
  const source=app.match(/function customerRegistrationDestinationPriority\(joinToken,businessSlug\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(source,'SPA must expose its post-auth customer destination priority');
  return vm.runInNewContext(`(${source})`);
}

test('successful public join hands the opaque QR token to customer registration',()=>{
  assert.match(brand,/customerLabel:\s*'My Peekaa'/);
  const customerHandoffUrl=extractedCustomerHandoffUrl();
  const token='A'.repeat(43);
  const handoff=customerHandoffUrl(token,'https://frenly.example/join.html?token=ignored');
  assert.equal(handoff,`https://frenly.example/index.html#/join?token=${token}`);
  assert.equal(
    customerHandoffUrl('token_with-safe_chars_12345678901234567890','https://frenly.example/tenant/app/join.html?token=ignored'),
    'https://frenly.example/tenant/app/index.html#/join?token=token_with-safe_chars_12345678901234567890'
  );
  assert.match(join,/renderSuccess\(\(data&&data\.business_name\)\|\|page\.name,joinToken\)/);
  assert.match(join,/id="openMyFrenly"[\s\S]*Create or open \$\{esc\(BRAND\.customerLabel\)\}/);
});

test('SPA normalizes only the canonical business slug contract from raw, join, portal and wallet links',()=>{
  const normalizeCustomerBusinessIntent=extractedBusinessIntentNormalizer();
  const base='https://frenly.example/tenant/app/index.html';
  assert.equal(normalizeCustomerBusinessIntent('KOPI-TIAM',base),'kopi-tiam');
  assert.equal(normalizeCustomerBusinessIntent('a',base),'',
    'the customer-claim intersection rejects one-character slugs that existing claim RPCs cannot consume');
  assert.equal(normalizeCustomerBusinessIntent('https://frenly.example/tenant/app/join.html?s=kopi-tiam',base),'kopi-tiam');
  assert.equal(normalizeCustomerBusinessIntent('https://frenly.example/tenant/app/index.html#/b/kopi-tiam',base),'kopi-tiam');
  assert.equal(normalizeCustomerBusinessIntent('https://frenly.example/tenant/app/index.html#/wallet/kopi-tiam',base),'kopi-tiam');
  assert.equal(normalizeCustomerBusinessIntent('#/customer?business=kopi-tiam',base),'kopi-tiam');
  assert.equal(normalizeCustomerBusinessIntent('has_underscore',base),'');
  assert.equal(normalizeCustomerBusinessIntent(`a${'b'.repeat(63)}`,base),'','slugs longer than 63 characters fail closed');
  assert.equal(normalizeCustomerBusinessIntent('https://frenly.example/not-a-frenly-link?business=kopi-tiam',base),'');
  assert.match(app,/return \/\^\[a-z0-9\]\[a-z0-9-\]\{1,62\}\$\/\.test\(normalized\)\?normalized:''/);
});

test('SPA preserves opaque join authority through registration and removes typed-slug claiming',()=>{
  const route=app.match(/async function route\(\)\{[\s\S]*?\/\* ---------- customer wallet ---------- \*\//)?.[0]||'';
  const registration=app.match(/async function runCustomerRegistrationProfileSubmission\([^\n]*\)[\s\S]*?(?=const CUSTOMER_PRIMARY_NAV)/)?.[0]||'';
  const claim=app.match(/async function renderCustomerClaim\(\)[\s\S]*?(?=function renderCustomerWalletUnavailable)/)?.[0]||'';

  assert.match(route,/h\.startsWith\('#\/join\?'\)[\s\S]*rememberPendingCustomerJoinToken\(joinToken\)/);
  assert.match(route,/if\(!S\.user&&h==='#\/join'\)return renderCustomerRegistration/);
  assert.match(registration,/customerRegistrationDestinationPriority\(pendingCustomerJoinToken,pendingCustomerBusinessSlug\)==='join'[\s\S]*nav\('#\/join'\)/);
  assert.match(app,/customer_join_business_from_qr_v89/);
  assert.match(app,/CUSTOMER_JOIN_SESSION_KEY='nestly\.customer\.pendingJoinToken'/);
  /* V289 (audit A3, G2): typed-slug DISCOVERY is still gone — no search, no directory, no
     listing. The guard now fires only when the visit carries no business at all; a visit that
     arrived through a business's own deep link reaches the claim form instead of being told to
     scan a QR it effectively just followed. */
  assert.match(claim,/if\(!invitationToken&&!businessIntent\)[\s\S]*Customers cannot search for or manually link a business/);
  assert.doesNotMatch(claim,/search for a business|browse businesses/i);
});

test('a delayed QR destination response cannot redirect after a newer route starts',async()=>{
  const source=app.match(/async function renderCustomerRegistration\([^\n]*\)\{[\s\S]*?\n\}\n\nconst CUSTOMER_LOCALES/)?.[0]
    ?.replace(/\n\nconst CUSTOMER_LOCALES[\s\S]*$/,'');
  assert.ok(source,'customer registration renderer must be extractable');

  let resolvePersonas;
  const personasResponse=new Promise(resolve=>{resolvePersonas=resolve});
  const navigations=[];
  const context={
    S:{user:{id:'customer-1'}},
    customerRegistrationDestinationPriority:extractedDestinationPriority(),
    pendingCustomerBusinessSlug:'kopi-tiam',
    pendingCustomerJoinToken:'',
    customerRecoveryVerified:()=>false,
    loadCustomerFeatureCapabilities:async()=>({customer_phone_registration:true,_load_error:false}),
    sb:{rpc:async(name)=>{
      if(name==='customer_get_profile')return {data:{profile:{full_name:'Demo Customer'}},error:null};
      if(name==='get_my_personas')return personasResponse;
      throw new Error(`unexpected RPC ${name}`);
    }},
    nav:value=>navigations.push(value),
    encodeURIComponent,
    renderCustomerCapabilityRetry:()=>{throw new Error('unexpected retry render')},
    renderCustomerWalletUnavailable:()=>{throw new Error('unexpected unavailable render')},
    renderCustomerRegistrationProfile:()=>{throw new Error('unexpected profile render')},
    loadCustomerPhoneOtpCapabilities:()=>{throw new Error('unexpected pre-auth capability read')},
    CUSTOMER_PHONE_OTP_RUNTIME_ENABLED:false,
    CUSTOMER_WHATSAPP_OTP_RUNTIME_ENABLED:false,
    customerRegistrationShell:()=>{throw new Error('unexpected pre-auth render')}
  };
  const renderCustomerRegistration=vm.runInNewContext(`(()=>{${source};return renderCustomerRegistration})()`,context);
  let current=true;
  const pending=renderCustomerRegistration(()=>current);
  await new Promise(resolve=>setImmediate(resolve));
  current=false;
  resolvePersonas({data:{customer:[{business_slug:'kopi-tiam'}]},error:null});
  await pending;

  assert.deepEqual(navigations,[],'the late persona result must not overwrite the newer route');
  assert.equal(context.pendingCustomerBusinessSlug,'kopi-tiam','stale work must preserve the pending QR intent');
});

test('post-registration destination retry never issues a second registration RPC',async()=>{
  const source=app.match(/async function runCustomerRegistrationProfileSubmission\([^]*?(?=function renderCustomerRegistrationProfile)/)?.[0];
  assert.ok(source,'registration submission and destination retry workflow must be extractable');

  const calls={registration:0,personas:0};
  const navigations=[];
  const retryButton={
    isConnected:true,
    disabled:false,
    span:{textContent:''},
    querySelector(){return this.span}
  };
  const context={
    CUI:{icon:()=>''},
    customerRegistrationShell:()=>{},
    $:id=>id==='customerDestinationRetry'?retryButton:null,
    sb:{rpc:async(name)=>{
      if(name==='customer_register_verified_phone'){
        calls.registration+=1;
        return {data:{outcome:'registered'},error:null};
      }
      if(name==='get_my_personas'){
        calls.personas+=1;
        return calls.personas===1
          ?{data:null,error:{message:'temporary persona failure'}}
          :{data:{customer:[{business_slug:'kopi-tiam'}]},error:null};
      }
      throw new Error(`unexpected RPC ${name}`);
    }},
    pendingCustomerBusinessSlug:'kopi-tiam',
    pendingCustomerJoinToken:'',
    pendingCustomerDestination:'',
    customerRegistrationDestinationPriority:extractedDestinationPriority(),
    takePendingCustomerDestination:fallback=>fallback,
    nav:value=>navigations.push(value),
    encodeURIComponent
  };
  const workflow=vm.runInNewContext(
    `(()=>{${source};return {runCustomerRegistrationProfileSubmission,resolveCustomerRegistrationDestination}})()`,
    context
  );
  const current=()=>true;
  const origin={isConnected:true};
  await workflow.runCustomerRegistrationProfileSubmission({
    registerRequest:()=>context.sb.rpc('customer_register_verified_phone'),
    resolveDestination:()=>workflow.resolveCustomerRegistrationDestination(current,origin),
    isCurrent:()=>current()&&origin.isConnected,
    onRegistrationError:()=>{throw new Error('unexpected registration error')}
  });

  assert.deepEqual(calls,{registration:1,personas:1});
  assert.equal(typeof retryButton.onclick,'function','persona failure must render a dedicated destination retry');
  await retryButton.onclick();
  assert.deepEqual(calls,{registration:1,personas:2},'retry must repeat only persona resolution');
  assert.deepEqual(navigations,['#/wallet/kopi-tiam']);
});

test('successful customer profile setup returns to the requested customer destination',async()=>{
  const source=app.match(/async function runCustomerRegistrationProfileSubmission\([^]*?(?=function renderCustomerRegistrationProfile)/)?.[0];
  assert.ok(source,'registration destination workflow must be extractable');
  const navigations=[];
  const context={
    CUI:{icon:()=>''},
    customerRegistrationShell:()=>{},
    $:()=>null,
    sb:{rpc:async name=>{
      if(name==='customer_register_verified_phone')return {data:{outcome:'registered'},error:null};
      if(name==='get_my_personas')return {data:{customer:[]},error:null};
      throw new Error(`unexpected RPC ${name}`);
    }},
    pendingCustomerBusinessSlug:'',
    pendingCustomerJoinToken:'',
    pendingCustomerDestination:'#/customer/bookings',
    customerRegistrationDestinationPriority:extractedDestinationPriority(),
    takePendingCustomerDestination(fallback=''){
      const destination=context.pendingCustomerDestination;
      context.pendingCustomerDestination='';
      return destination||fallback;
    },
    nav:value=>navigations.push(value),
    encodeURIComponent
  };
  const workflow=vm.runInNewContext(
    `(()=>{${source};return {runCustomerRegistrationProfileSubmission,resolveCustomerRegistrationDestination}})()`,
    context
  );
  const origin={isConnected:true};
  await workflow.runCustomerRegistrationProfileSubmission({
    registerRequest:()=>context.sb.rpc('customer_register_verified_phone'),
    resolveDestination:()=>workflow.resolveCustomerRegistrationDestination(()=>true,origin),
    isCurrent:()=>origin.isConnected,
    onRegistrationError:()=>{throw new Error('unexpected registration error')}
  });

  assert.deepEqual(navigations,['#/customer/bookings']);
  assert.equal(context.pendingCustomerDestination,'','the intended route must be consumed after navigation');
});

test('a delayed registration response cannot repaint or resolve a destination after its form is gone',async()=>{
  const source=app.match(/async function runCustomerRegistrationProfileSubmission\([^]*?\n\}/)?.[0];
  assert.ok(source,'registration submission continuation helper must be extractable');
  const run=vm.runInNewContext(`(${source})`);
  let settle;
  const registrationResponse=new Promise(resolve=>{settle=resolve});
  let current=true,connected=true,destinationCalls=0,errorPaints=0;
  const pending=run({
    registerRequest:()=>registrationResponse,
    resolveDestination:async()=>{destinationCalls+=1},
    isCurrent:()=>current&&connected,
    onRegistrationError:()=>{errorPaints+=1}
  });
  current=false;connected=false;
  settle({data:{outcome:'registered'},error:null});
  assert.equal(await pending,'stale');
  assert.equal(destinationCalls,0);
  assert.equal(errorPaints,0);
});

test('success keeps a truthful counter fallback and uses labelled vector actions',()=>{
  assert.match(join,/show the mobile number you joined with at the counter to collect points/i);
  assert.match(join,/id="openMyFrenly"/);
  assert.match(join,/<svg class="icon"[\s\S]*aria-hidden="true" focusable="false"/);
  assert.doesNotMatch(join,/\p{Extended_Pictographic}/u,'join states must not use emoji as structural icons');
  assert.match(join,/\.btn\{[\s\S]*min-height:48px[\s\S]*touch-action:manipulation/);
  assert.match(join,/\.btn:focus-visible/);
  assert.match(join,/id="joinSuccessTitle" tabindex="-1"/);
  assert.match(join,/\$\('joinSuccessTitle'\)\?\.focus\(\)/);
  assert.match(join,/id="formErr" role="alert" aria-live="assertive"/);
});

test('join request, consent, Turnstile and guest isolation contracts stay unchanged',()=>{
  assert.match(join,/credentials:'omit'/);
  assert.match(join,/<input type="checkbox" id="f_consent">/);
  assert.doesNotMatch(join,/<input[^>]+id="f_consent"[^>]+\bchecked\b/);
  assert.match(join,/action:'public_join'/);
  assert.match(join,/turnstile_token:turnstileToken/);
  assert.match(join,/publicJoin\(\{body:\{join_token:joinToken,name:nameEl\.value\.trim\(\),phone:cleanPhone\(\),\s*email:emailEl\.value\.trim\(\)\|\|null,consent:consentEl\.checked,\s*turnstile_token:turnstileToken\}\}\)/);
});
