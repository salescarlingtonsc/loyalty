import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const section=(source,start,end)=>{
  const from=source.indexOf(start),to=source.indexOf(end,from);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return source.slice(from,to);
};

test('customer programmes are QR-joined only and automatic global matching is not run',async()=>{
  const app=await read('app/index.html');
  const context=section(app,'async function loadCustomerSurfaceContext','async function renderCustomerProgrammes');
  assert.doesNotMatch(context,/syncVerifiedCustomerRelationshipsOnce|customer_sync_verified_relationships_v81/);
  const programmes=section(app,'async function renderCustomerProgrammes','const ACTIVE_CUSTOMER_BOOKING_REQUEST_STATUSES');
  assert.match(programmes,/scan its Nestly QR/i);
  assert.match(programmes,/renderCustomerFirstProgrammeQuest\(\)/);
  assert.doesNotMatch(programmes,/href="#\/claim"|Add programme|customerRelationshipCheckActionHtml/);
  const claim=section(app,'async function renderCustomerClaim','function renderCustomerWalletUnavailable');
  assert.match(claim,/if\(!invitationToken\)[\s\S]*Customers cannot search for or manually link a business/);
});

test('opaque QR join survives refresh and has no typed slug authority',async()=>{
  const [app,join,gateway,validation]=await Promise.all([
    read('app/index.html'),read('app/join.html'),
    read('supabase/functions/public-join/index.ts'),
    read('supabase/functions/_shared/validation.ts')
  ]);
  assert.match(app,/CUSTOMER_JOIN_SESSION_KEY='nestly\.customer\.pendingJoinToken'/);
  assert.match(app,/sessionStorage\.setItem\(CUSTOMER_JOIN_SESSION_KEY/);
  assert.match(app,/customer_join_business_from_qr_v89/);
  assert.match(app,/clearWriteAttempt\('nestly\.customer\.joinQr'\);rememberPendingCustomerJoinToken\(''\)/);
  assert.match(join,/getJoinToken\(\)/);
  assert.match(join,/join_token:joinToken/);
  assert.match(join,/#\/join\?token=/);
  assert.doesNotMatch(join,/function getSlug|body:\{slug/);
  assert.match(gateway,/internal_public_join_page_v89/);
  assert.match(gateway,/internal_public_join_v89/);
  assert.match(gateway,/validJoinTokenPayload/);
  assert.match(validation,/function validJoinTokenPayload/);
});

test('customer can scan a business-issued QR from first use and from persistent navigation',async()=>{
  const app=await read('app/index.html');
  const scanner=section(app,'function customerJoinTokenFromQr','function sortStaffWorkspaces');
  assert.match(scanner,/openCustomerJoinScanner/);
  assert.match(scanner,/getUserMedia\(\{video:\{facingMode:\{ideal:'environment'\}\}/);
  assert.match(scanner,/id="customerJoinScannerImage" type="file" accept="image\/\*"/);
  assert.match(scanner,/rememberPendingCustomerJoinToken\(token\);close\(\{restoreFocus:false\}\);nav\('#\/join'\)/);
  assert.match(app,/function renderCustomerFirstProgrammeQuest/);
  assert.match(app,/firstQuest:'Your first programme'/);
  assert.match(app,/id="customerFirstScan"/);
  assert.match(app,/id="customerFirstScan"/);
  assert.match(app,/id="customerNavScan"/);
});

test('customer can switch linked programmes without returning to the programme index',async()=>{
  const app=await read('app/index.html');
  const wallet=section(app,'async function renderCustomerWallet','async function renderCustomerInAppInbox');
  assert.match(wallet,/const programmeSwitcher=programmeCards\.length>1/);
  assert.match(wallet,/class="customer-programme-switcher"/);
  assert.match(wallet,/aria-label="Switch loyalty programme"/);
  assert.match(wallet,/aria-current="true"/);
  assert.match(wallet,/#\/wallet\/\$\{encodeURIComponent\(business\.slug\|\|''\)\}/);
});

test('customer Home surfaces rewards, bookings and messages before programme drill-down',async()=>{
  const app=await read('app/index.html');
  const home=section(app,'function renderActionableWalletHome','async function renderCustomerWallet');
  assert.match(home,/customerHomeOverview\.walletCards/);
  assert.match(home,/customerHomeOverview\.activeRequestCount/);
  assert.match(home,/customerHomeOverview\.messageCount/);
  assert.match(home,/aria-label="Customer overview"/);
  assert.match(home,/Rewards &amp; value/);
  assert.match(home,/#\/customer\/bookings/);
  assert.match(home,/#\/customer\/messages/);
});

test('scanned QR waits for a completed profile, then outranks wallet destinations and is consumed',async()=>{
  const app=await read('app/index.html');
  const prioritySource=app.match(/function customerRegistrationDestinationPriority\(joinToken,businessSlug\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(prioritySource,'missing post-auth customer destination priority helper');
  const priority=new Function(`${prioritySource};return customerRegistrationDestinationPriority;`)();
  const opaqueJoinToken='opaque_join_token_1234567890';
  const nextRoute=priority(opaqueJoinToken,'already-linked-business')==='join'
    ?'#/join'
    :'#/wallet';
  assert.equal(nextRoute,'#/join','a scanned QR must outrank existing wallet and business destinations');

  const registration=section(app,'async function renderCustomerRegistration','async function renderCustomerClaim');
  assert.match(registration,/customer_get_profile[\s\S]*if\(profile\?\.profile!==null&&profile\?\.profile!==undefined\)\{[\s\S]*customerRegistrationDestinationPriority\(pendingCustomerJoinToken,pendingCustomerBusinessSlug\)==='join'[\s\S]*nav\('#\/join'\);return;/);
  assert.match(registration,/return renderCustomerRegistrationProfile\(isRouteCurrent\)/);
  const passwordEntry=section(app,'function renderCustomerPasswordSignIn','async function renderCustomerOtpStart');
  assert.match(passwordEntry,/signInWithPasskey\(\{options:\{captchaToken:challenge\}\}\)[\s\S]*resetClientSessionState\(\{preserveInvitation:true\}\);route\(\)/);
  assert.match(app,/if\(h==='#\/join'\)return renderCustomerQrJoin\(\)/);
  const consume=section(app,'async function renderCustomerQrJoin','async function renderCustomerClaim');
  assert.match(consume,/customer_join_business_from_qr_v89/);
  assert.doesNotMatch(consume,/nav\('#\/wallet'\)[\s\S]*customer_join_business_from_qr_v89/);
});

test('passkey sign-in and complete customer passkey management are capability gated',async()=>{
  const app=await read('app/index.html');
  assert.match(app,/experimental:\{passkey:true\}/);
  assert.match(app,/function customerPasskeySupported\(\{management=false\}=\{\}\)/);
  assert.match(app,/async function maybeOfferCustomerPasskeySetup\(\{isCurrent=\(\)=>true\}=\{\}\)/);
  assert.match(app,/await maybeOfferCustomerPasskeySetup\(\{isCurrent:isRouteCurrent\}\)/);
  assert.match(app,/id="customerPasskeyPromptAdd"[\s\S]*Enable now/);
  assert.match(app,/sb\.auth\.passkey\.list\(\)[\s\S]*if\(passkeys\.length\)return false/);
  assert.match(app,/\.modal\{position:fixed;inset:0;z-index:210/,
    'passkey setup must stay above the delayed PWA install prompt on mobile');
  assert.match(app,/sb\.auth\.signInWithPasskey\(\{options:\{captchaToken:challenge\}\}\)/);
  assert.match(app,/if\(!passkeySupported\|\|!captchaToken\)[\s\S]*Complete the security check before using Face ID, Touch ID or your passkey/);
  assert.match(app,/captchaToken='';[\s\S]*signInWithPasskey[\s\S]*captchaControl\?\.reset\(\)/);
  assert.match(app,/sb\.auth\.registerPasskey\(\)/);
  assert.match(app,/sb\.auth\.passkey\.list\(\)/);
  assert.match(app,/sb\.auth\.passkey\.update\(\{passkeyId:button\.dataset\.passkeyRename,friendlyName:name\}\)/);
  assert.match(app,/name\.length>120/);
  assert.match(app,/Passkey rename cancelled/);
  assert.match(app,/sb\.auth\.passkey\.delete\(\{passkeyId:button\.dataset\.passkeyDelete\}\)/);
  assert.match(app,/error\?\.code==='passkey_disabled'/);
  assert.match(app,/webauthn_credential_not_found[\s\S]*remove it, then add a new passkey/);
});

test('customer booking and changes require the business v89 enablement',async()=>{
  const app=await read('app/index.html');
  const wallet=section(app,'async function renderCustomerWallet','async function renderCustomerInAppInbox');
  assert.match(wallet,/customer_get_business_actions_v89/);
  assert.match(wallet,/capabilities\.booking_request&&bookingEnabled/);
  assert.match(app,/customerFeatures\.customer_actions&&appointmentChangesEnabled&&a\.status==='booked'/);
  const bookings=section(app,'async function bookingsPage','/* ---------- grow recommender');
  assert.match(bookings,/business_get_customer_capabilities_v89/);
  assert.match(bookings,/business_set_customer_capabilities_v89/);
  assert.match(bookings,/p_booking_enabled/);
  assert.match(bookings,/p_redemption_enabled/);
  assert.match(bookings,/p_appointment_changes_enabled/);
});

test('Bookings shows enabled zero-history firms and hides only disabled firms without history',async()=>{
  const app=await read('app/index.html');
  const composeSource=app.match(/const ACTIVE_CUSTOMER_BOOKING_REQUEST_STATUSES=[\s\S]*?function composeCustomerBookingGroups\([^\n]*\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(composeSource,'missing customer booking grouping contract');
  const compose=vm.runInNewContext(`(()=>{${composeSource};return composeCustomerBookingGroups})()`);
  const enabled={business:{slug:'enabled-spa',name:'Enabled Spa'},booking:{enabled:true}};
  const disabled={business:{slug:'disabled-shop',name:'Disabled Shop'},booking:{enabled:false}};
  const groups=compose([enabled,disabled],null,[
    {card:enabled,data:{items:[]},error:null},
    {card:disabled,data:{items:[]},error:null}
  ]);
  assert.deepEqual(Array.from(groups,group=>group.business_slug),['enabled-spa']);
  assert.equal(groups[0].bookingEnabled,true);
  const history=compose([disabled],{items:[{
    request_id:'past-1',business_slug:'disabled-shop',
    business_name:'Disabled Shop',status:'declined'
  }]},[{card:disabled,data:{items:[]},error:null}]);
  assert.equal(history.length,1,'disabled businesses retain real booking history');
  assert.equal(history[0].bookingEnabled,false);

  const bookings=section(app,'async function renderCustomerBookings','async function renderCustomerMessages');
  assert.match(bookings,/customer_list_programmes_v89/);
  assert.match(bookings,/customer_get_business_actions_v89/);
  assert.match(bookings,/response\.data\?\.booking\?\.enabled===true/);
  assert.match(bookings,/group\.bookingEnabled&&group\.business_slug[\s\S]*>Book now</);
});

test('loyalty owner can enable customer QR redemption without a bookings module',async()=>{
  const app=await read('app/index.html');
  const loyalty=section(app,'async function loyaltyPage','async function retentionPage');
  assert.match(loyalty,/const canWriteLoyalty=canWriteModule\('loyalty'\)/);
  assert.match(loyalty,/const canManageLoyalty=S\.myRole==='owner'&&canWriteLoyalty/);
  assert.match(loyalty,/id="loyaltyCustomerRedemptionEnabled"/);
  assert.match(loyalty,/canManageLoyalty\?'<button class="btn sm" id="saveLoyaltyCustomerRedemption"/);
  assert.doesNotMatch(loyalty,/canWriteModule\('bookings'\)/,
    'the loyalty redemption switch must not depend on the bookings module');

  const helperSource=app.match(/async function saveCustomerRedemptionCapabilityV89\(\{businessId,redemptionEnabled\}\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(helperSource,'missing customer redemption capability saver');
  const calls=[];
  const sb={rpc:async(name,args)=>{
    calls.push({name,args});
    if(name==='business_get_customer_capabilities_v89')return {
      data:{booking_enabled:true,redemption_enabled:false,appointment_changes_enabled:true},error:null
    };
    return {data:{redemption_enabled:args.p_redemption_enabled},error:null};
  }};
  const save=vm.runInNewContext(`(${helperSource})`,{sb});
  const result=await save({businessId:'retail-firm',redemptionEnabled:true});
  assert.equal(result.data.redemption_enabled,true);
  assert.deepEqual(JSON.parse(JSON.stringify(calls[1])),{
    name:'business_set_customer_capabilities_v89',
    args:{
      p_business:'retail-firm',p_booking_enabled:true,
      p_redemption_enabled:true,p_appointment_changes_enabled:true
    }
  },'saving redemption must preserve freshly loaded booking and appointment settings');
});

test('redemption is pending until merchant scan and scanner supports iPhone camera and image fallback',async()=>{
  const [app,vercel]=await Promise.all([read('app/index.html'),read('app/vercel.json')]);
  assert.match(app,/customer_create_redemption_intent_v89/);
  assert.match(app,/Pending merchant scan/);
  assert.match(app,/points are not redeemed until the business scans and confirms/i);
  assert.match(app,/merchant_scan_redemption_qr_v93/);
  assert.match(app,/p_branch:branchId/);
  assert.match(app,/Scan customer QR/);
  assert.match(app,/jsqr@1\.4\.0\/dist\/jsQR\.js/);
  assert.match(app,/integrity="sha384-b5Ya4Bq3qCyz39m2ISh\+4DxjAIljdeFwK\/BsXLuj9gugaNwAcj\/ia15fxNZL9Nlx"/);
  assert.match(app,/getUserMedia\(\{video:\{facingMode:\{ideal:'environment'\}\}/);
  assert.match(app,/Camera access was not available\. Choose a QR image/);
  assert.match(app,/id="merchantScannerImage" type="file" accept="image\/\*"/);
  assert.match(app,/createImageBitmap|URL\.createObjectURL/);
  assert.match(app,/customer_cancel_redemption_intent_v89/);
  assert.match(app,/customer_get_redemption_intent_v89/);
  assert.match(app,/CUI\.activateDialog\(overlay/);
  assert.match(app,/activeCustomerRedemptionCleanup=close/);
  assert.match(app,/setTimeout\(poll/);
  assert.match(app,/if\(state==='completed'\)finish\('completed',data\)/);
  assert.match(app,/Redeemed!/);
  assert.match(app,/customer-redemption-complete/);
  assert.match(app,/customerSuccessCue\(\)/);
  assert.match(app,/Close — keep pending/);
  assert.match(app,/Cancel redemption/);
  assert.match(app,/writeAttemptKey\(slot,String\(intent\.intent_id\)\)/);
  assert.match(app,/Redemption cancelled\. No points were redeemed\./);
  assert.equal(JSON.parse(vercel).headers[0].headers.find(item=>item.key==='Permissions-Policy').value.includes('camera=(self)'),true);
});

test('Quick Earn scanner follows front-desk and manager loyalty-write assignments',async()=>{
  const app=await read('app/index.html');
  const helperSource=app.match(/function canScanCustomerRedemption\(\{createSales,clientsReadable,loyaltyWritable\}=\{\}\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(helperSource,'missing Quick Earn redemption scan access projection');
  const canScan=vm.runInNewContext(`(${helperSource})`);
  const managerRw={createSales:true,clientsReadable:true,loyaltyWritable:true};
  const frontDeskRw={createSales:true,clientsReadable:true,loyaltyWritable:true};
  const frontDeskReadOnly={createSales:true,clientsReadable:true,loyaltyWritable:false};
  const managerLoyaltyOff={createSales:true,clientsReadable:true,loyaltyWritable:false};
  assert.equal(canScan(managerRw),true);
  assert.equal(canScan(frontDeskRw),true);
  assert.equal(canScan(frontDeskReadOnly),false);
  assert.equal(canScan(managerLoyaltyOff),false);
  assert.equal(canScan({...frontDeskRw,clientsReadable:false}),false);
  assert.match(app,/actions:canScanRedemption\?CUI\.action\(\{id:'tScanRedemption'/);
  assert.match(app,/if\(canScanRedemption\)\$\(\'tScanRedemption\'\)\.onclick/);
  assert.match(app,/Redemption scanning requires Loyalty write access/);
});

test('classic and catalog rewards share the v89 availability enum and produce truthful intent arguments',async()=>{
  const app=await read('app/index.html');
  const wallet=section(app,'async function renderCustomerWallet','async function renderCustomerInAppInbox');
  assert.match(wallet,/available_at_counter:'Available at counter'/);
  assert.match(wallet,/disabled:'Unavailable for redemption'/);
  assert.doesNotMatch(wallet,/Ask the business to enable QR redemption|QR redemption is not enabled by this business/);
  assert.match(wallet,/not_started:'Available soon'/);
  assert.match(wallet,/ended:'Offer ended'/);
  assert.match(wallet,/limit_reached:'Claim limit reached'/);
  assert.match(wallet,/insufficient_balance:'More points needed'/);
  assert.match(wallet,/actionsResult\.data\?\.redemption\?\.classic/);
  assert.match(wallet,/customerRewardCanRedeem\(r,redemptionEnabled\)/);
  assert.match(wallet,/customerRedemptionIntentArgsV89/);

  const canRedeemSource=app.match(/function customerRewardCanRedeem\(reward,redemptionEnabled\)\{[\s\S]*?\n\}/)?.[0];
  const argsSource=app.match(/function customerRedemptionIntentArgsV89\(\{businessId,reward,idempotencyKey\}\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(canRedeemSource&&argsSource);
  const helpers=vm.runInNewContext(`(()=>{${canRedeemSource}\n${argsSource};return {canRedeem:customerRewardCanRedeem,args:customerRedemptionIntentArgsV89}})()`);
  const classic={redemption_kind:'classic_points',availability:'available_at_counter'};
  const catalog={id:'reward-1',redemption_kind:'catalog_reward',availability:'available_at_counter'};
  assert.equal(helpers.canRedeem(classic,true),true);
  assert.equal(helpers.canRedeem(catalog,true),true);
  assert.equal(helpers.canRedeem({...catalog,availability:'insufficient_balance'},true),false);
  assert.deepEqual(JSON.parse(JSON.stringify(helpers.args({
    businessId:'firm-1',reward:classic,idempotencyKey:'attempt-1'
  }))),{
    p_business:'firm-1',p_reward:null,p_idempotency_key:'attempt-1',
    p_redemption_kind:'classic_points'
  });
  assert.deepEqual(JSON.parse(JSON.stringify(helpers.args({
    businessId:'firm-1',reward:catalog,idempotencyKey:'attempt-2'
  }))),{
    p_business:'firm-1',p_reward:'reward-1',p_idempotency_key:'attempt-2',
    p_redemption_kind:'catalog_reward'
  });
});

test('merchant scan success remains visible as a classic or catalog fulfilment receipt',async()=>{
  const app=await read('app/index.html');
  const viewSource=app.match(/function merchantRedemptionReceiptView\(data=\{\}\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(viewSource,'missing merchant redemption receipt projection');
  const view=vm.runInNewContext(`(${viewSource})`,{money:cents=>`SGD ${(cents/100).toFixed(2)}`});
  const classic=view({
    redemption_kind:'classic_points',customer_name:'Aisha Lim',
    reward_label:'Redeem 800 points',points_spent:800,credit_cents:2000,
    operation_id:'op-classic'
  });
  assert.equal(classic.customerName,'Aisha Lim');
  assert.equal(classic.pointsSpent,800);
  assert.match(classic.fulfilment,/SGD 20\.00 has been added/);
  assert.equal(classic.operationId,'op-classic');
  const catalog=view({
    redemption_kind:'catalog_reward',customer_name:'Ben Tan',
    reward_label:'Free coffee',points_spent:120,credit_cents:0,
    operation_id:'op-catalog'
  });
  assert.equal(catalog.rewardLabel,'Free coffee');
  assert.match(catalog.fulfilment,/Provide the reward shown above/);
  assert.match(app,/<dt>Customer<\/dt>/);
  assert.match(app,/<dt>Reward<\/dt>/);
  assert.match(app,/<dt>Points spent<\/dt>/);
  assert.match(app,/<dt>Operation reference<\/dt>/);
  assert.match(app,/panel\.innerHTML=merchantRedemptionReceiptHtml\(data\)/);
  assert.doesNotMatch(app,/close\(\);toast\(data\?\.replayed===true/);
});

test('unlinked public booking remains guest-capable but programme joining is QR-only',async()=>{
  const app=await read('app/index.html');
  const portal=section(app,'async function renderPortal','async function boot');
  const unlinked=section(portal,'Booking as an unlinked guest','  }).catch(()=>{});');
  assert.match(unlinked,/booking can still be submitted safely/i);
  assert.match(unlinked,/visit the participating business and scan its current Nestly QR/i);
  assert.doesNotMatch(unlinked,/href="#\/claim|Add programme/);
});
