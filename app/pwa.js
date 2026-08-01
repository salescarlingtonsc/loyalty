(function nestlyPwaBootstrap(globalObject){
  'use strict';

  const SW_URL='/sw.js';
  const isSecure=globalObject.isSecureContext
    || ['localhost','127.0.0.1'].includes(globalObject.location?.hostname);
  const isStandalone=()=>globalObject.matchMedia?.('(display-mode: standalone)').matches
    || globalObject.navigator?.standalone===true;
  const isIos=()=>/iphone|ipad|ipod/i.test(globalObject.navigator?.userAgent||'')
    || (globalObject.navigator?.platform==='MacIntel'
      && globalObject.navigator?.maxTouchPoints>1);
  const isNative=()=>Boolean(globalObject.Capacitor?.isNativePlatform?.());
  let installEvent=null;
  let registration=null;
  let updateRequested=false;
  let installTimer=0;

  function statusHost(){
    let host=document.getElementById('pwaStatus');
    if(host)return host;
    host=document.createElement('div');
    host.id='pwaStatus';
    host.className='pwa-status';
    host.hidden=true;
    host.setAttribute('role','status');
    host.setAttribute('aria-live','polite');
    document.body.appendChild(host);
    return host;
  }

  function promptHost(){
    let host=document.getElementById('pwaPrompt');
    if(host)return host;
    host=document.createElement('aside');
    host.id='pwaPrompt';
    host.className='pwa-prompt';
    host.hidden=true;
    host.setAttribute('aria-live','polite');
    document.body.appendChild(host);
    return host;
  }

  function hidePrompt(){
    const host=promptHost();
    host.hidden=true;
    host.replaceChildren();
  }

  function showPrompt({title,body,actionLabel,onAction,dismissLabel='Not now'}){
    const host=promptHost();
    host.replaceChildren();
    const copy=document.createElement('div');
    copy.className='pwa-prompt-copy';
    const heading=document.createElement('strong');
    heading.textContent=title;
    const detail=document.createElement('span');
    detail.textContent=body;
    copy.append(heading,detail);
    const actions=document.createElement('div');
    actions.className='pwa-prompt-actions';
    if(actionLabel&&onAction){
      const action=document.createElement('button');
      action.type='button';action.className='pwa-action';
      action.textContent=actionLabel;
      action.addEventListener('click',onAction,{once:true});
      actions.appendChild(action);
    }
    const dismiss=document.createElement('button');
    dismiss.type='button';dismiss.className='pwa-dismiss';
    dismiss.setAttribute('aria-label',dismissLabel);
    dismiss.textContent='×';
    dismiss.addEventListener('click',hidePrompt,{once:true});
    actions.appendChild(dismiss);
    host.append(copy,actions);
    host.hidden=false;
  }

  function renderConnectivity(){
    if(document.getElementById('offlineTitle'))return;
    const host=statusHost();
    if(globalObject.navigator.onLine){
      host.hidden=true;
      host.replaceChildren();
      return;
    }
    host.replaceChildren();
    const copy=document.createElement('span');
    copy.textContent='You’re offline. Reconnect to load live Peekaa data.';
    const retry=document.createElement('button');
    retry.type='button';retry.textContent='Retry';
    retry.addEventListener('click',()=>globalObject.location.reload());
    host.append(copy,retry);
    host.hidden=false;
  }

  async function requestInstall(){
    if(!installEvent)return;
    const event=installEvent;
    installEvent=null;
    hidePrompt();
    await event.prompt();
    const choice=await event.userChoice;
    if(choice?.outcome!=='accepted')installEvent=event;
  }

  function offerInstall(){
    if(isStandalone()||isNative()||!globalObject.navigator.onLine)return;
    if(installEvent){
      showPrompt({
        title:'Install Peekaa',
        body:'Keep customer and business tools one tap away in a standalone app window.',
        actionLabel:'Install',onAction:requestInstall
      });
      return;
    }
    if(isIos()){
      showPrompt({
        title:'Add Peekaa to your Home Screen',
        body:'In Safari, tap Share, then choose “Add to Home Screen”.'
      });
    }
  }

  function offerUpdate(worker){
    showPrompt({
      title:'A Peekaa update is ready',
      body:'Refresh once to use the latest app shell. Your saved business data is not stored in this cache.',
      actionLabel:'Update now',
      onAction:()=>{
        updateRequested=true;
        worker.postMessage({type:'SKIP_WAITING'});
      }
    });
  }

  function watchRegistration(nextRegistration){
    registration=nextRegistration;
    if(registration.waiting&&globalObject.navigator.serviceWorker.controller){
      offerUpdate(registration.waiting);
    }
    registration.addEventListener('updatefound',()=>{
      const worker=registration.installing;
      if(!worker)return;
      worker.addEventListener('statechange',()=>{
        if(worker.state==='installed'&&globalObject.navigator.serviceWorker.controller){
          offerUpdate(worker);
        }
      });
    });
  }

  async function register(){
    if(!isSecure||isNative()||!('serviceWorker' in globalObject.navigator))return;
    try{
      watchRegistration(await globalObject.navigator.serviceWorker.register(SW_URL,{scope:'/',updateViaCache:'none'}));
    }catch(error){
      console.warn('Peekaa offline shell could not be registered.',error);
    }
  }

  globalObject.addEventListener('beforeinstallprompt',event=>{
    event.preventDefault();
    installEvent=event;
    globalObject.clearTimeout(installTimer);
    installTimer=globalObject.setTimeout(offerInstall,3500);
  });
  globalObject.addEventListener('appinstalled',()=>{
    installEvent=null;
    hidePrompt();
  });
  globalObject.addEventListener('online',renderConnectivity);
  globalObject.addEventListener('offline',renderConnectivity);
  globalObject.navigator?.serviceWorker?.addEventListener('controllerchange',()=>{
    if(updateRequested)globalObject.location.reload();
  });
  document.addEventListener('visibilitychange',()=>{
    if(document.visibilityState==='visible')registration?.update?.();
  });

  globalObject.NestlyPWA=Object.freeze({
    offerInstall,
    checkForUpdate:()=>registration?.update?.(),
    isStandalone
  });

  const boot=()=>{
    renderConnectivity();
    register();
    if(isIos()&&!isStandalone()&&!isNative()){
      installTimer=globalObject.setTimeout(offerInstall,8000);
    }
  };
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});
  else boot();
})(window);
