(function nestlyCustomerPushFactory(globalObject){
  'use strict';

  const REGISTER_RPC='customer_register_push_subscription_v95';
  const UNREGISTER_RPC='customer_unregister_push_subscription_v95';
  const subscribers=new Set();
  let backend=null;
  let currentUserId='';
  let confirmedUserId='';
  let confirmedEndpoint='';
  let subscriptionId='';
  let foreignSubscription={endpoint:'',ownerUserId:''};
  let operation=null;
  let sessionEpoch=0;

  const isIos=()=>/iphone|ipad|ipod/i.test(globalObject.navigator?.userAgent||'')
    || (globalObject.navigator?.platform==='MacIntel'&&globalObject.navigator?.maxTouchPoints>1);
  const isStandalone=()=>globalObject.matchMedia?.('(display-mode: standalone)').matches
    || globalObject.navigator?.standalone===true;
  const vapidKey=()=>String(globalObject.__FRENLY_RUNTIME_CONFIG__?.webPushPublicKey||'').trim();
  const supported=()=>Boolean(globalObject.isSecureContext
    && 'Notification' in globalObject
    && 'serviceWorker' in globalObject.navigator
    && 'PushManager' in globalObject);

  function base64UrlBytes(value){
    const normalized=value.replace(/-/g,'+').replace(/_/g,'/');
    const binary=globalObject.atob(normalized+'='.repeat((4-normalized.length%4)%4));
    return Uint8Array.from(binary,character=>character.charCodeAt(0));
  }

  function status(){
    const permission=globalObject.Notification?.permission||'default';
    if(!supported())return {state:'unsupported',label:'Unavailable',detail:'Push notifications are not supported in this browser.'};
    if(isIos()&&!isStandalone())return {state:'install_required',label:'Install required',detail:'On iPhone or iPad, add Peekaa to your Home Screen, open the installed app, then enable notifications here.'};
    if(!vapidKey())return {state:'unconfigured',label:'Unavailable',detail:'Notifications aren’t available yet.'};
    if(permission==='denied')return {state:'blocked',label:'Blocked',detail:'Notifications are blocked in your device settings. Allow Peekaa there, then return to this page.'};
    if(!currentUserId)return {state:'signed_out',label:'Off',detail:'Sign in to manage device notifications.'};
    if(foreignSubscription.endpoint&&foreignSubscription.ownerUserId!==currentUserId){
      return {state:'account_conflict',label:'Needs reset',detail:'This browser notification connection belongs to another Peekaa account. Reset it explicitly to enable notifications for this account; the other account will not be revoked.'};
    }
    if(confirmedEndpoint&&confirmedUserId===currentUserId)return {state:'enabled',label:'On',detail:'Transactional updates are enabled on this device.'};
    return {state:'disabled',label:'Off',detail:'Get booking, points, reward, quest, and birthday updates on this device.'};
  }

  function visible(value){
    return !['unsupported','unconfigured'].includes(String(value?.state||''));
  }

  function publish(){
    const value=status();
    subscribers.forEach(listener=>listener(value));
    return value;
  }

  async function subscription(){
    if(!supported())return null;
    const registration=await globalObject.navigator.serviceWorker.ready;
    return registration.pushManager.getSubscription();
  }

  function rememberForeignSubscription(endpoint,ownerUserId=''){
    foreignSubscription={endpoint:String(endpoint||''),ownerUserId:String(ownerUserId||'')};
  }

  function setAuthenticatedUser(userId){
    const nextUserId=String(userId||'');
    if(nextUserId===currentUserId)return publish();
    if(confirmedEndpoint&&confirmedUserId){
      rememberForeignSubscription(confirmedEndpoint,confirmedUserId);
    }
    currentUserId=nextUserId;
    confirmedUserId='';
    confirmedEndpoint='';
    subscriptionId='';
    sessionEpoch+=1;
    operation=null;
    if(nextUserId&&foreignSubscription.ownerUserId===nextUserId){
      foreignSubscription={endpoint:'',ownerUserId:''};
    }
    return publish();
  }

  function clearSession(){
    return setAuthenticatedUser('');
  }

  async function registerWithServer(nextSubscription,{userId=currentUserId,epoch=sessionEpoch}={}){
    if(!userId||userId!==currentUserId)throw new Error('A signed-in customer is required.');
    const serialized=nextSubscription.toJSON();
    const endpoint=String(serialized?.endpoint||nextSubscription.endpoint||'');
    const p256dh=String(serialized?.keys?.p256dh||'');
    const authSecret=String(serialized?.keys?.auth||'');
    if(!endpoint||!p256dh||!authSecret)throw new Error('The browser returned an incomplete push subscription.');
    const {data,error}=await backend.rpc(REGISTER_RPC,{
      p_endpoint:endpoint,
      p_p256dh:p256dh,
      p_auth_secret:authSecret,
      p_idempotency_key:globalObject.crypto.randomUUID()
    });
    const serverId=String(data?.subscription_id||'');
    if(error||data?.status!=='active'||!serverId)throw error||new Error('Push registration was not confirmed.');
    if(userId!==currentUserId||epoch!==sessionEpoch)throw new Error('The signed-in customer changed.');
    confirmedUserId=userId;
    confirmedEndpoint=endpoint;
    subscriptionId=serverId;
    foreignSubscription={endpoint:'',ownerUserId:''};
  }

  async function reconcile(){
    if(!backend||!supported()||!vapidKey()||(isIos()&&!isStandalone())
      ||globalObject.Notification.permission!=='granted'){
      confirmedUserId='';
      confirmedEndpoint='';
      subscriptionId='';
      return publish();
    }
    const existing=await subscription();
    if(!existing){
      confirmedUserId='';confirmedEndpoint='';subscriptionId='';
      foreignSubscription={endpoint:'',ownerUserId:''};
      return publish();
    }
    if(foreignSubscription.endpoint===existing.endpoint
      &&foreignSubscription.ownerUserId!==currentUserId)return publish();
    if(existing.endpoint===confirmedEndpoint&&confirmedUserId===currentUserId&&subscriptionId)return publish();
    const userId=currentUserId,epoch=sessionEpoch;
    try{
      await registerWithServer(existing,{userId,epoch});
    }catch{
      if(userId===currentUserId&&epoch===sessionEpoch){
        rememberForeignSubscription(existing.endpoint,foreignSubscription.ownerUserId);
      }
      confirmedUserId='';
      confirmedEndpoint='';
      subscriptionId='';
    }
    return publish();
  }

  async function enable(){
    if(operation)return operation;
    const userId=currentUserId,epoch=sessionEpoch;
    const nextOperation=(async()=>{
      const before=status();
      if(!['disabled','blocked'].includes(before.state))return before;
      if(before.state==='blocked')return before;

      const permission=await globalObject.Notification.requestPermission();
      if(permission!=='granted'){confirmedEndpoint='';return publish()}

      let nextSubscription;
      let created=false;
      try{
        const registration=await globalObject.navigator.serviceWorker.ready;
        nextSubscription=await registration.pushManager.getSubscription();
        if(!nextSubscription){
          nextSubscription=await registration.pushManager.subscribe({
            userVisibleOnly:true,
            applicationServerKey:base64UrlBytes(vapidKey())
          });
          created=true;
        }
        try{
          await registerWithServer(nextSubscription,{userId,epoch});
        }catch(error){
          if(created)await nextSubscription.unsubscribe().catch(()=>false);
          throw error;
        }
        return publish();
      }catch(error){
        confirmedUserId='';
        confirmedEndpoint='';
        subscriptionId='';
        publish();
        throw error;
      }
    })();
    operation=nextOperation;
    return nextOperation.finally(()=>{if(operation===nextOperation)operation=null});
  }

  async function disable(){
    if(operation)return operation;
    if(!currentUserId||confirmedUserId!==currentUserId||!subscriptionId)return publish();
    const userId=currentUserId,epoch=sessionEpoch;
    const nextOperation=(async()=>{
      const existing=await subscription();
      if(subscriptionId){
        const {data,error}=await backend.rpc(UNREGISTER_RPC,{
          p_subscription:subscriptionId,
          p_idempotency_key:globalObject.crypto.randomUUID()
        });
        if(error||!['revoked','not_found'].includes(String(data?.status||''))){
          throw error||new Error('Push removal was not confirmed.');
        }
      }
      if(userId!==currentUserId||epoch!==sessionEpoch)throw new Error('The signed-in customer changed.');
      if(existing)await existing.unsubscribe();
      confirmedUserId='';
      confirmedEndpoint='';
      subscriptionId='';
      return publish();
    })();
    operation=nextOperation;
    return nextOperation.finally(()=>{if(operation===nextOperation)operation=null});
  }

  async function recover(){
    if(operation)return operation;
    if(status().state!=='account_conflict')return status();
    const userId=currentUserId,epoch=sessionEpoch;
    const nextOperation=(async()=>{
      const existing=await subscription();
      if(existing&&existing.endpoint===foreignSubscription.endpoint){
        await existing.unsubscribe();
      }
      if(userId!==currentUserId||epoch!==sessionEpoch)throw new Error('The signed-in customer changed.');
      foreignSubscription={endpoint:'',ownerUserId:''};
      publish();
      const registration=await globalObject.navigator.serviceWorker.ready;
      let nextSubscription=await registration.pushManager.getSubscription();
      if(!nextSubscription){
        nextSubscription=await registration.pushManager.subscribe({
          userVisibleOnly:true,
          applicationServerKey:base64UrlBytes(vapidKey())
        });
      }
      try{
        await registerWithServer(nextSubscription,{userId,epoch});
      }catch(error){
        await nextSubscription.unsubscribe().catch(()=>false);
        rememberForeignSubscription(nextSubscription.endpoint,'');
        publish();
        throw error;
      }
      return publish();
    })();
    operation=nextOperation;
    return nextOperation.finally(()=>{if(operation===nextOperation)operation=null});
  }

  function buttonLabel(value){
    if(value.state==='enabled')return 'Turn off device notifications';
    if(value.state==='account_conflict')return 'Reset for this account';
    if(value.state==='install_required')return 'How to enable notifications';
    if(value.state==='signed_out')return 'Sign in to enable notifications';
    return 'Turn on device notifications';
  }

  function bindButton(button,{statusHost=null}={}){
    if(!button)return ()=>{};
    const paint=value=>{
      button.hidden=!visible(value);
      const setting=button.closest?.('.customer-push-setting');
      if(setting)setting.hidden=!visible(value);
      button.dataset.pushState=value.state;
      button.setAttribute('aria-pressed',value.state==='enabled'?'true':'false');
      button.querySelector('[data-push-label]')?.replaceChildren(buttonLabel(value));
      if(statusHost){
        statusHost.textContent=value.detail;
        statusHost.dataset.pushState=value.state;
      }
      button.disabled=['unsupported','unconfigured','signed_out'].includes(value.state);
    };
    const listener=value=>{
      if(!button.isConnected){subscribers.delete(listener);return}
      paint(value);
    };
    subscribers.add(listener);paint(status());
    button.addEventListener('click',async()=>{
      const value=status();
      if(value.state==='install_required'){
        globalObject.NestlyPWA?.offerInstall?.();
        if(statusHost)statusHost.textContent=value.detail;
        return;
      }
      button.disabled=true;
      if(statusHost)statusHost.textContent=value.state==='enabled'
        ?'Turning off notifications…'
        :value.state==='account_conflict'?'Resetting this browser connection…':'Waiting for your permission…';
      try{
        await (value.state==='enabled'?disable():value.state==='account_conflict'?recover():enable());
      }catch{
        if(statusHost)statusHost.textContent='This device could not be updated. Nothing is shown as enabled. Try again.';
      }finally{
        if(button.isConnected)paint(status());
      }
    });
    return ()=>subscribers.delete(listener);
  }

  function configure({rpc,userId}={}){
    if(typeof rpc!=='function')throw new TypeError('An authenticated RPC function is required.');
    backend={rpc};
    setAuthenticatedUser(userId);
    return Object.freeze({
      bindButton,
      reconcile,
      status,
      enable,
      disable,
      recover
    });
  }

  globalObject.NestlyCustomerPush=Object.freeze({configure,setAuthenticatedUser,clearSession});
})(window);
