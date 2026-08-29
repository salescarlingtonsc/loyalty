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
  /* nestly_v596: a signed-out scan still ends in registration — the opaque token is never traded
     for a typed slug — but it now NAMES the business first. Before the sheet ran here the visitor
     was dropped on the generic Peekaa sign-in card and the scan read as broken. */
  assert.match(route,/if\(!S\.user&&h==='#\/join'\)\{[\s\S]*?return renderCustomerRegistration\(isRouteCurrent\);\n\s*\}/);
  const signedOutJoin=route.match(/if\(!S\.user&&h==='#\/join'\)\{[\s\S]*?return renderCustomerRegistration\(isRouteCurrent\);\n\s*\}/)[0];
  assert.match(signedOutJoin,/confirmCustomerJoinV571\(pendingCustomerJoinToken,isRouteCurrent\)/,
    'the business is named before a stranger is asked to sign up');
  /* nestly_v599: the remembered answer is deliberately NOT consulted here. v596 did, and the
     result was that only the FIRST scan on a device ever showed the sheet — every scan afterwards
     skipped it and dropped the person on the plain sign-in card. The answer exists to stop the
     sheet re-appearing on the far side of the sign-up, where the person is signed in and a
     different branch runs. Here, a scan is always answered; the in-memory flag only stops a
     re-render of the same visit stacking a second sheet. */
  assert.match(signedOutJoin,/!customerJoinAskedThisVisitV599/,
    'a re-render of the same visit does not stack a second sheet');
  assert.doesNotMatch(signedOutJoin,/customerJoinAlreadyConfirmedV596/,
    'but a stored answer never suppresses a fresh scan');
  assert.match(signedOutJoin,/rememberCustomerJoinConfirmedV596\(pendingCustomerJoinToken,pendingCustomerJoinSlugV587\)/,
    'the answer, and the slug the preview taught us, are both kept');
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

// ---------------------------------------------------------------------------
// V292 (audit G9). The owner ruled that this page stays. It therefore has to
// stop lying: every failure -- an expired QR, a revoked QR, a business that
// switched join off, a rate limit, a dead network -- rendered the same
// "Something went wrong. Please check your connection." with an infinite retry
// button. Three of those four are not connection problems and will never be
// fixed by pressing Try again.
// ---------------------------------------------------------------------------

test('the gateway status survives the fetch so the page can tell the truth about why',()=>{
  assert.match(join,/error\.status=response\.status;/);
  assert.match(join,/error\.retryAfter=Number\(payload\?\.retry_after\)\|\|0;/);
});

test('an expired, revoked or disabled QR is terminal, not an infinite retry loop',()=>{
  // public-join answers 404 for a token that fails TOKEN_PATTERN and for a token
  // internal_public_join_page_v89 will not resolve: expired, revoked, replaced or
  // join-disabled. 403 is an origin refusal. Neither is retryable by the customer.
  assert.match(join,/function renderExpiredLink\(\)/);
  assert.match(join,/This QR code is no longer active/);
  assert.match(join,/Ask the counter for a new one/);
  assert.match(join,/if\(err\?\.status===404\|\|err\?\.status===403\)\{ renderExpiredLink\(\); return; \}/);
  // The terminal card must not offer a retry, which is the whole point.
  const expired=join.match(/function renderExpiredLink\(\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(expired,'join page must expose its expired-QR state');
  assert.doesNotMatch(expired,/id="retryBtn"/);
  assert.doesNotMatch(expired,/check your connection/i);
});

test('a rate limit says wait, and a network failure still says retry', ()=>{
  assert.match(join,/function renderBusyGateway\(retryAfterSeconds\)/);
  assert.match(join,/Too many sign-ups from this network/);
  assert.match(join,/if\(err\?\.status===429\)\{ renderBusyGateway\(err\.retryAfter\); return; \}/);
  const busy=join.match(/function renderBusyGateway\(retryAfterSeconds\)\{[\s\S]*?\n\}/)?.[0];
  assert.match(busy,/id="retryBtn"/,'a rate limit is genuinely retryable, later');
  assert.match(busy,/have not been sent/,'the customer must know nothing was submitted');
  // The connection message survives for the case it is actually about.
  assert.match(join,/function renderLoadError\(\)/);
  assert.match(join,/Please check your connection and try again\./);
});

test('a QR that dies mid-form does not invite the customer to retype everything',()=>{
  const submit=join.match(/\$\('joinForm'\)\.addEventListener\('submit'[\s\S]*?\n  \}\);/)?.[0];
  assert.ok(submit,'join page must expose its submit handler');
  assert.match(submit,/if\(err\?\.status===404\|\|err\?\.status===403\)\{ renderExpiredLink\(\); return; \}/);
});

test('the mobile rule matches the app that has to find this member again',()=>{
  // The SPA matches customers on /^[89]\d{7}$/. Accepting a 3xx/6xx landline here
  // created a member the customer app could never match. The gateway stays more
  // permissive on purpose; the client guard is the tighter of the two.
  assert.match(join,/const JOIN_MOBILE_PATTERN=\/\^\[89\]\\d\{7\}\$\//);
  assert.doesNotMatch(join,/\[3689\]/,'the join form must not accept Singapore landline prefixes');
  assert.match(join,/starting with 8 or 9/);
  assert.match(app,/\/\^\[89\]\\d\{7\}\$\//,'the SPA rule this mirrors must still exist');
});

test('an optional email is validated before it is sent, not after it is rejected',()=>{
  assert.match(join,/const JOIN_EMAIL_PATTERN=\/\^\[\^\\s@\]\+@\[\^\\s@\]\+\\\.\[\^\\s@\]\+\$\//);
  assert.match(join,/function emailValid\(\)/);
  assert.match(join,/return !value\|\|\(value\.length<=254&&JOIN_EMAIL_PATTERN\.test\(value\)\)/);
  assert.match(join,/&& emailValid\(\)/);
  // novalidate stays: every rule on this form is enforced in script and surfaced
  // in one live region, so letting the browser raise a second, untranslated
  // bubble would put two different errors on screen for one field.
  assert.match(join,/<form id="joinForm" novalidate>/);
});
