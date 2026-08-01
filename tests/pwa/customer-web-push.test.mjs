import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const PUBLIC_VAPID='B'.repeat(87);

function pushControllerHarness(source,{
  rpcResult={data:{subscription_id:'018f0000-0000-7000-8000-000000000001',status:'active'},error:null},
  rpcImpl=null,
  permission='default',
  userId='user-a'
}={}){
  const calls=[];
  let subscriptionSequence=0;
  let existing=null;
  const makeSubscription=()=>{
    const suffix=++subscriptionSequence===1?'one':'two';
    const next={
      endpoint:`https://push.example.test/subscription/${suffix}`,
      toJSON:()=>({endpoint:next.endpoint,keys:{p256dh:`public-${suffix}`,auth:`auth-${suffix}`}}),
      unsubscribe:async()=>{calls.push(['unsubscribe',next.endpoint]);if(existing===next)existing=null;return true}
    };
    return next;
  };
  const subscription=makeSubscription();
  let firstSubscriptionIssued=false;
  const Notification={
    permission,
    async requestPermission(){
      calls.push(['permission']);
      Notification.permission='granted';
      return 'granted';
    }
  };
  const window={
    isSecureContext:true,
    Notification,
    PushManager:function PushManager(){},
    __FRENLY_RUNTIME_CONFIG__:{webPushPublicKey:PUBLIC_VAPID},
    navigator:{
      userAgent:'Test mobile browser',
      serviceWorker:{ready:Promise.resolve({pushManager:{
        getSubscription:async()=>existing,
        subscribe:async options=>{
          const next=firstSubscriptionIssued?makeSubscription():subscription;
          firstSubscriptionIssued=true;
          calls.push(['subscribe',options,next.endpoint]);existing=next;return next;
        }
      }})}
    },
    matchMedia:()=>({matches:true}),
    atob:value=>Buffer.from(value,'base64').toString('binary'),
    crypto:{randomUUID:()=>`018f0000-0000-7000-8000-${String(calls.length).padStart(12,'0')}`},
    Uint8Array,
  };
  window.window=window;
  vm.runInNewContext(source,{window,Uint8Array,Set,TypeError,Error});
  const configure=nextUserId=>window.NestlyCustomerPush.configure({
    rpc:async(name,args)=>{
      calls.push(['rpc',name,args]);
      return rpcImpl?rpcImpl(name,args):rpcResult;
    },
    userId:nextUserId
  });
  const client=configure(userId);
  return {calls,client,configure,Notification,subscription,window};
}

test('customer push permission is only requested from the explicit enable action',async()=>{
  const harness=pushControllerHarness(await read('app/customer-push.js'));
  assert.equal(harness.client.status().state,'disabled');
  assert.deepEqual(harness.calls,[]);

  await harness.client.enable();
  assert.equal(harness.calls[0][0],'permission');
  assert.equal(harness.calls[1][0],'subscribe');
  assert.equal(harness.calls[2][1],'customer_register_push_subscription_v95');
  assert.equal(harness.calls[2][2].p_endpoint,harness.subscription.endpoint);
  assert.equal(harness.calls[2][2].p_p256dh,'public-one');
  assert.equal(harness.calls[2][2].p_auth_secret,'auth-one');
  assert.match(harness.calls[2][2].p_idempotency_key,/^[0-9a-f-]{36}$/);
  assert.equal(harness.client.status().state,'enabled');
});

test('customer push never reports enabled without authenticated server confirmation',async()=>{
  const harness=pushControllerHarness(await read('app/customer-push.js'),{
    rpcResult:{data:null,error:{code:'PGRST202'}}
  });
  await assert.rejects(harness.client.enable());
  assert.equal(harness.client.status().state,'disabled');
  assert.ok(harness.calls.some(([kind])=>kind==='unsubscribe'));
});

test('customer push revokes the server UUID before removing the browser subscription',async()=>{
  const source=await read('app/customer-push.js');
  const harness=pushControllerHarness(source,{
    rpcImpl:async name=>name==='customer_register_push_subscription_v95'
      ?{data:{subscription_id:'018f0000-0000-7000-8000-000000000001',status:'active'},error:null}
      :{data:{subscription_id:'018f0000-0000-7000-8000-000000000001',status:'revoked'},error:null}
  });
  await harness.client.enable();
  await harness.client.disable();
  const revoke=harness.calls.find(([,name])=>name==='customer_unregister_push_subscription_v95');
  assert.equal(revoke[2].p_subscription,'018f0000-0000-7000-8000-000000000001');
  assert.match(revoke[2].p_idempotency_key,/^[0-9a-f-]{36}$/);
  assert.ok(harness.calls.findIndex(([,name])=>name==='customer_unregister_push_subscription_v95')
    <harness.calls.findIndex(([kind])=>kind==='unsubscribe'));
  assert.equal(harness.client.status().state,'disabled');
});

test('repeated route renders do not create duplicate server registration operations',async()=>{
  const harness=pushControllerHarness(await read('app/customer-push.js'),{permission:'granted'});
  await harness.client.enable();
  await harness.client.reconcile();
  await harness.client.reconcile();
  assert.equal(
    harness.calls.filter(([,name])=>name==='customer_register_push_subscription_v95').length,
    1
  );
});

test('A logout then B sign-in never leaks enabled state or lets B revoke A, and offers explicit recovery',async()=>{
  const uuidA='018f0000-0000-7000-8000-00000000000a';
  const uuidB='018f0000-0000-7000-8000-00000000000b';
  const source=await read('app/customer-push.js');
  const harness=pushControllerHarness(source,{
    rpcImpl:async(name,args)=>{
      if(name==='customer_unregister_push_subscription_v95'){
        return {data:{subscription_id:args.p_subscription,status:'revoked'},error:null};
      }
      return {
        data:{
          subscription_id:args.p_endpoint.endsWith('/one')?uuidA:uuidB,
          status:'active'
        },
        error:null
      };
    }
  });
  await harness.client.enable();
  assert.equal(harness.client.status().state,'enabled');

  harness.window.NestlyCustomerPush.clearSession();
  assert.equal(harness.client.status().state,'signed_out');
  const customerB=harness.configure('user-b');
  const label={textContent:'',replaceChildren(value){this.textContent=value}};
  const button={
    isConnected:true,dataset:{},
    setAttribute(name,value){this[name]=value},
    querySelector:()=>label,
    addEventListener(){}
  };
  customerB.bindButton(button);
  assert.equal(customerB.status().state,'account_conflict');
  assert.equal(button.dataset.pushState,'account_conflict');
  assert.equal(label.textContent,'Reset for this account');
  assert.match(customerB.status().detail,/another Peekaa account/);

  await customerB.disable();
  assert.equal(
    harness.calls.filter(([,name])=>name==='customer_unregister_push_subscription_v95').length,
    0,
    'B must never revoke A using A’s server UUID'
  );
  await customerB.recover();
  assert.equal(customerB.status().state,'enabled');
  assert.equal(button.dataset.pushState,'enabled');
  assert.ok(harness.calls.some(([kind,endpoint])=>kind==='unsubscribe'&&endpoint.endsWith('/one')));
  const registrations=harness.calls.filter(([,name])=>name==='customer_register_push_subscription_v95');
  assert.equal(registrations.at(-1)[2].p_endpoint,'https://push.example.test/subscription/two');
  assert.equal(
    harness.calls.filter(([,name])=>name==='customer_unregister_push_subscription_v95').length,
    0
  );
});

test('iOS requires the installed PWA before notification permission can be requested',async()=>{
  const source=await read('app/customer-push.js');
  const harness=pushControllerHarness(source);
  harness.client.status();
  assert.match(source,/isIos\(\)&&!isStandalone\(\)/);
  assert.match(source,/add Peekaa to your Home Screen/i);
  assert.doesNotMatch(source,/(setTimeout|DOMContentLoaded)[\s\S]{0,160}requestPermission/);
});

test('service worker accepts only six customer-safe event types and routes clicks to business context',async()=>{
  const source=await read('app/sw.js');
  const eventTypes=source.match(/const CUSTOMER_PUSH_TYPES=new Set\(\[([\s\S]*?)\]\)/)?.[1]||'';
  assert.equal((eventTypes.match(/'[^']+'/g)||[]).length,6);
  for(const eventType of [
    'value_expiry','reward_ready','visit_progress','birthday_benefit',
    'booking_request_received','appointment_time_changed'
  ])assert.match(eventTypes,new RegExp(`'${eventType}'`));
  assert.match(source,/business_slug\|\|data\?\.programme_slug/);
  assert.match(source,/clients\.matchAll\(\{type:'window',includeUncontrolled:true\}\)/);
  assert.match(source,/existing\.navigate\(target\)/);
  assert.match(source,/clients\.openWindow\(target\)/);
  assert.doesNotMatch(eventTypes,/marketing|campaign|promotion/);
});

test('customer account and profile controls are touch-sized, accessible, private, and mobile responsive',async()=>{
  const html=await read('app/index.html');
  assert.match(html,/id="customerPushMenuControl"[^>]*aria-pressed="false"/);
  assert.match(html,/id="customerPushProfileControl"[^>]*aria-pressed="false"/);
  assert.match(html,/data-push-status role="status" aria-live="polite"/);
  assert.match(html,/Businesses cannot send promotional push notifications/);
  assert.match(html,/\.customer-account-menu \.menu a,\.customer-account-menu \.menu button\{[^}]*min-height:44px/s);
  assert.match(html,/@media\(max-width:560px\)\{\.customer-push-setting\{grid-template-columns:1fr\}/);
  assert.match(html,/function resetClientSessionState[\s\S]*NestlyCustomerPush\?\.clearSession/);
  assert.match(html,/onAuthStateChange\(\(event,session\)=>\{[\s\S]*NestlyCustomerPush\?\.setAuthenticatedUser/);
  assert.match(html,/configure\(\{rpc:\(name,args\)=>sb\.rpc\(name,args\),userId:S\.user\?\.id\}\)/);
});

test('privacy notice explains device-notification data and delivery purpose',async()=>{
  const privacy=await read('app/privacy.html');
  assert.match(
    privacy,
    /browser-generated push endpoint and subscription encryption and authentication key material/
  );
  assert.match(privacy,/appointment, expiring-value, reward, visit-progress or birthday notifications/);
  assert.match(privacy,/device-notification transport/);
});
