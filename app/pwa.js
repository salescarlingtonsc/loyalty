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

  // A dismissal has to stick, otherwise the prompt returns on the next route change.
  const PWA_PROMPT_DISMISSED_KEY='peekaa-pwa-prompt-dismissed';
  const PWA_PROMPT_DISMISS_MS=30*24*60*60*1000;

  function promptDismissedRecently(){
    try{
      const at=Number(globalObject.localStorage?.getItem(PWA_PROMPT_DISMISSED_KEY)||0);
      return Number.isFinite(at)&&at>0&&(Date.now()-at)<PWA_PROMPT_DISMISS_MS;
    }catch{return false}
  }

  function hidePrompt(){
    const host=promptHost();
    host.hidden=true;
    host.replaceChildren();
    try{globalObject.localStorage?.setItem(PWA_PROMPT_DISMISSED_KEY,String(Date.now()))}catch{}
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
    if(promptDismissedRecently())return;
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

  /* V321 (owner, 2026-08-14: "the website still keeps refreshing itself. - remove this").
     isUnsafeToAutoUpdate() is gone with the auto-update it guarded. It tried to judge whether a
     moment was safe to reload the page under someone — no field focused, no dialog open — and
     "safe-looking" is simply not the same as "invited": reading a customer's profile, comparing
     two figures on a report, or thinking, are all safe by that test and all ruined by a reload.
     It could not have worked anyway. */
  function applyUpdate(worker){
    if(!worker)return;
    updateRequested=true;
    worker.postMessage({type:'SKIP_WAITING'});
  }

  /* The prompt below already existed, as the fallback for moments the old code deemed unsafe. It
     is now the ONLY path: Peekaa never reloads itself. A person presses "Update now", or dismisses
     it and keeps working on the shell they already have until they next open the app. */
  function offerUpdate(worker){
    showPrompt({
      title:'A Peekaa update is ready',
      body:'Refresh once to use the latest app shell. Your saved business data is not stored in this cache.',
      actionLabel:'Update now',
      onAction:()=>applyUpdate(worker)
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
  /* V321: the PEEKAA_SW_ACTIVATED listener is DELETED. V289 had already caught it as "a second
     uninvited reload path" — the broadcast reaches every open tab, not just the one that accepted
     an update — and narrowed it to tabs that looked idle. Narrowing was not enough: a tab that
     merely looks idle still belongs to someone. The tab that asked for the update reloads through
     updateRequested/controllerchange above, which is the consented path and the only one left.
     Other tabs pick the new shell up whenever they are next opened. */
  document.addEventListener('visibilitychange',()=>{
    /* Still only CHECKS. With the auto-apply gone this can no longer reload anything; the most it
       does now is raise the dismissible "update is ready" prompt. */
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
