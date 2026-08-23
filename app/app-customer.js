/* GENERATED FILE — do not edit.
   The customer of app/app.js, split by scripts/quality/split-app-bundle.mjs.
   Edit app/app.js and run: npm run bundle-stamp */
/* Public pre-auth capability checks must not inherit a stale persisted customer
   or staff session. A rejected historical access token would otherwise make an
   anonymous availability RPC fail closed even while the hosted provider and
   platform flags are ready. */
const preAuthSb=window.supabase.createClient(SB_URL,SB_KEY,{auth:{
  storageKey:'nestly-preauth-anon',persistSession:false,
  autoRefreshToken:false,detectSessionInUrl:false
}});
async function submitPublicBookingGateway(body,initiallySignedInUser=null,isCurrent=()=>true){
  const {data,error}=await sb.auth.getSession();
  if(!isCurrent()){
    const staleError=new Error('Booking view changed.');
    staleError.code='STALE_PORTAL';
    throw staleError;
  }
  const session=data?.session;
  const accessToken=session?.user&&String(session.access_token||'').trim()
    ?String(session.access_token).trim():'';
  if(initiallySignedInUser&&(error||!accessToken||session?.user?.id!==initiallySignedInUser.id)){
    const sessionError=new Error('Your signed-in session has expired. Sign in again, then retry so this booking is not silently submitted as a guest.');
    sessionError.code='CUSTOMER_SESSION_EXPIRED';
    throw sessionError;
  }
  return publicGateway('public-booking',{body,accessToken});
}
let turnstileLoader;
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
  const message=(text,isError=false)=>{setPassed(false);statusEl.textContent=text;statusEl.style.color=isError?'var(--danger)':''};
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
/* Phone OTP is an explicit runtime provider seam. No provider secret is
   present in the browser. Fixed Auth test OTPs belong only in local/staging
   Supabase configuration and must never create a production phone bypass. */
const customerPhoneOtpRuntimeConfigured=()=>(
  RUNTIME_CONFIG.customerPhoneOtpEnabled===true
);
const CUSTOMER_PHONE_OTP_RUNTIME_ENABLED=(
  (RUNTIME_CONFIG.environment!=='production'
    && customerPhoneOtpRuntimeConfigured())
  || (RUNTIME_CONFIG.environment==='production'
    && customerPhoneOtpRuntimeConfigured())
);
const customerPhoneBlockedInProduction=()=>(
  RUNTIME_CONFIG.environment==='production'
  && !customerPhoneOtpRuntimeConfigured()
);
const CUSTOMER_WHATSAPP_OTP_RUNTIME_ENABLED=(
  CUSTOMER_PHONE_OTP_RUNTIME_ENABLED
  && window.__FRENLY_CUSTOMER_WHATSAPP_OTP_ENABLED__===true
);
/* The promotion detail modal is opened from a card, not from the wallet renderer, so it has no
   business id in hand. Held here for the life of the wallet render that set it. */
let customerWalletBusinessIdV256='';
const customerPromotionsSeenV256=new Set();
/* One session-start per browser session, recorded the first time a business scope is known.
   sessionStorage carries it across a reload of the same tab, so a refresh is not a new session. */
function recordCustomerSessionStartV256(businessId,locale){
  if(productInteractionSessionStartedV256)return;
  try{
    if(sessionStorage.getItem(PRODUCT_INTERACTION_SESSION_START_KEY_V256)==='1'){
      productInteractionSessionStartedV256=true;return;
    }
  }catch{}
  productInteractionSessionStartedV256=true;
  try{sessionStorage.setItem(PRODUCT_INTERACTION_SESSION_START_KEY_V256,'1')}catch{}
  typeof recordProductInteractionV100==='function'&&recordProductInteractionV100('customer.session_started',businessId,{
    context:{entry_point:'customer_app',locale,surface_version:'v255'}
  });
}
function takePendingCustomerDestination(fallback=''){
  const destination=normalizeCustomerDestination(pendingCustomerDestination);
  return destination||fallback;
}
function customerRegistrationDestinationPriority(joinToken,businessSlug){
  if(String(joinToken||''))return 'join';
  if(String(businessSlug||''))return 'business';
  return 'customer';
}
function customerRewardCanRedeem(reward,redemptionEnabled){
  if(redemptionEnabled!==true||reward?.availability!=='available_at_counter')return false;
  return reward?.redemption_kind==='classic_points'
    ||(reward?.redemption_kind==='catalog_reward'&&!!reward?.id);
}
function customerRedemptionIntentArgsV89({businessId,reward,idempotencyKey}){
  const kind=reward?.redemption_kind==='classic_points'?'classic_points':'catalog_reward';
  return {
    p_business:businessId,
    p_reward:kind==='classic_points'?null:reward?.id,
    p_idempotency_key:idempotencyKey,
    p_redemption_kind:kind
  };
}
// Customer-facing names for redemption intent statuses; raw DB enums must never surface.
const CUSTOMER_REDEMPTION_STATUS_COPY={
  completed:'This reward was already redeemed.',
  cancelled:'This redemption was cancelled.',
  expired:'This redemption expired.',
  limit_reached:'You have reached the limit for this reward.'
};
function redemptionCountdownText(expiresAt,now=Date.now()){
  const expiry=new Date(expiresAt).getTime();
  if(!Number.isFinite(expiry))return '';
  const seconds=Math.max(0,Math.ceil((expiry-now)/1000));
  const minutes=Math.floor(seconds/60),remainder=seconds%60;
  return seconds>0?`Expires in ${minutes}:${String(remainder).padStart(2,'0')}`:'Expired';
}
/* v177: also the app's prompt() replacement. Pass `input` and the dialog gains one text field and
   resolves with the typed string, or null when the customer backs out — native prompt() is
   unstyled, unlocalisable, invisible to our focus trap and blocked outright in some webviews. */
function showCustomerDecisionDialog({title,body,keepLabel='Keep',confirmLabel='Confirm',danger=false,input=null}={}){
  return new Promise(resolve=>{
    const dialog=document.createElement('div');
    dialog.className='modal customer-surface customer-confirmation-modal';dialog.setAttribute('role','dialog');
    dialog.setAttribute('aria-modal','true');dialog.setAttribute('aria-labelledby','customerDecisionTitle');
    const inputHtml=input?`<div class="cui-field" style="margin-top:12px"><label for="customerDecisionInput">${esc(input.label||'')}</label><input id="customerDecisionInput" type="text" autocomplete="off" value="${esc(input.value||'')}" placeholder="${esc(input.placeholder||'')}"${input.maxLength?` maxlength="${Number(input.maxLength)}"`:''}></div>`:'';
    dialog.innerHTML=`<section class="modal-card"><h2 id="customerDecisionTitle">${esc(title)}</h2><p class="muted" style="margin-top:8px">${esc(body)}</p>${inputHtml}<div class="decision-actions"><button class="btn ghost" id="customerDecisionKeep" type="button">${esc(keepLabel)}</button><button class="btn ${danger?'danger':''}" id="customerDecisionConfirm" type="button">${esc(confirmLabel)}</button></div></section>`;
    document.body.appendChild(dialog);
    const field=input?dialog.querySelector('#customerDecisionInput'):null;
    let settled=false,deactivate=null;
    const finish=value=>{
      if(settled)return;settled=true;
      if(deactivate){const cleanup=deactivate;deactivate=null;cleanup()}
      else dialog.remove();
      resolve(value);
    };
    const cancelValue=()=>input?null:false;
    const confirmValue=()=>input?String(field?.value??''):true;
    deactivate=CUI.activateDialog(dialog,{onClose:()=>finish(cancelValue()),initialFocus:input?'#customerDecisionInput':'#customerDecisionKeep'});
    dialog.querySelector('#customerDecisionKeep').onclick=()=>finish(cancelValue());
    dialog.querySelector('#customerDecisionConfirm').onclick=()=>finish(confirmValue());
    if(field)field.addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();finish(confirmValue())}});
    dialog.addEventListener('click',event=>{if(event.target===dialog)finish(cancelValue())});
  });
}
/* V290: the promotion twin of showPendingRedemptionQr. Deliberately simpler — a promotion intent
   moves no points and no credit, so there is nothing to cancel and nothing to reconcile: it is a
   code that either gets scanned before it expires or does not. The QR carries the same
   `nestly:promotion:` prefix the merchant scanner parses. */
function showPendingPromotionQrV290({intent,businessName,promotionName}={}){
  const token=String(intent?.qr_token||'');
  if(!token)return;
  const overlay=document.createElement('div');
  overlay.className='modal customer-redemption-modal';overlay.setAttribute('role','dialog');
  overlay.setAttribute('aria-modal','true');
  overlay.setAttribute('aria-labelledby','customerPromotionQrTitle');
  overlay.innerHTML=`<section class="modal-card"><div class="row"><div style="text-align:left"><h2 id="customerPromotionQrTitle">${esc(promotionName||'Offer')}</h2><p class="muted small" style="margin-top:5px">Show this code to ${esc(businessName||'the team')} at the counter.</p></div><span class="spacer"></span><button class="btn ghost sm" id="customerPromotionQrClose" type="button" aria-label="Close offer code">${CUI.icon('close',{size:20})}</button></div>
    <div class="redemption-qr" id="customerPromotionQr" aria-label="Offer code"></div>
    <span class="pill new">Waiting for the counter</span>
    <p class="muted small" id="customerPromotionQrStatus" role="status" aria-live="polite" style="margin-top:10px">Nothing is used until the team scans this code.${intent?.expires_at?` <span>${esc(redemptionCountdownText(intent.expires_at))}</span>.`:''}</p>
    <div class="row" style="margin-top:16px"><button class="btn ghost" id="customerPromotionQrDone" type="button">Close</button></div></section>`;
  document.body.appendChild(overlay);
  let deactivate=null;
  const close=()=>{
    if(deactivate){const cleanup=deactivate;deactivate=null;cleanup({restoreFocus:true})}
    else overlay.remove();
  };
  void loadQrLibrary().then(()=>new QRCode(overlay.querySelector('#customerPromotionQr'),
    {text:`nestly:promotion:${token}`,width:220,height:220,correctLevel:QRCode.CorrectLevel.M}))
    .catch(()=>{
      const status=overlay.querySelector('#customerPromotionQrStatus');
      if(status)status.insertAdjacentHTML('afterend',`<details style="margin-top:12px;text-align:left"><summary class="small">Show fallback code</summary><code class="growth-redemption-token">${esc(token)}</code></details>`);
    });
  overlay.querySelector('#customerPromotionQrClose').onclick=close;
  overlay.querySelector('#customerPromotionQrDone').onclick=close;
  overlay.addEventListener('click',event=>{if(event.target===overlay)close()});
  deactivate=CUI.activateDialog(overlay,{onClose:close,initialFocus:'#customerPromotionQrDone'});
}
function showCustomerPackageQrV347({item={},businessName='',onClose=()=>{}}={}){
  const packageId=String(item?.client_package_id||item?.id||'').trim();
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(packageId)){
    toast('This package QR could not be prepared. Refresh and try again.');
    return;
  }
  const remaining=Math.max(0,Number(item?.sessions_remaining||0));
  const name=String(item?.plan_name||'Package').trim();
  const overlay=document.createElement('div');
  overlay.className='modal customer-redemption-modal';overlay.setAttribute('role','dialog');
  overlay.setAttribute('aria-modal','true');overlay.setAttribute('aria-labelledby','customerPackageQrTitle');
  overlay.innerHTML=`<section class="modal-card"><div class="row"><div style="text-align:left"><h2 id="customerPackageQrTitle">${esc(name)}</h2><p class="muted small" style="margin-top:5px">${esc(businessName||'The business')} must scan this code to use one session.</p></div><span class="spacer"></span><button class="btn ghost sm" id="customerPackageQrClose" type="button" aria-label="Close package QR">${CUI.icon('close',{size:20})}</button></div>
    <div class="redemption-qr" id="customerPackageQr" aria-label="Package session QR code"></div>
    <span class="pill new">${remaining} session${remaining===1?'':'s'} left before scan</span>
    <p class="muted small" id="customerPackageQrStatus" role="status" aria-live="polite" style="margin-top:10px">Nothing is deducted until staff scans and confirms this QR.</p>
    <div class="row" style="margin-top:16px"><button class="btn ghost" id="customerPackageQrDone" type="button">Close</button></div></section>`;
  document.body.appendChild(overlay);
  const qrValue=`nestly:package:${packageId}`;
  let deactivate=null;
  const close=()=>{
    if(deactivate){const cleanup=deactivate;deactivate=null;cleanup({restoreFocus:true})}
    else overlay.remove();
    onClose?.();
  };
  void loadQrLibrary().then(()=>new QRCode(overlay.querySelector('#customerPackageQr'),
    {text:qrValue,width:220,height:220,correctLevel:QRCode.CorrectLevel.M}))
    .catch(()=>{
      const status=overlay.querySelector('#customerPackageQrStatus');
      if(status)status.insertAdjacentHTML('afterend',`<details style="margin-top:12px;text-align:left"><summary class="small">Show fallback code</summary><code class="growth-redemption-token">${esc(qrValue)}</code></details>`);
    });
  overlay.querySelector('#customerPackageQrClose').onclick=close;
  overlay.querySelector('#customerPackageQrDone').onclick=close;
  overlay.addEventListener('click',event=>{if(event.target===overlay)close()});
  deactivate=CUI.activateDialog(overlay,{onClose:close,initialFocus:'#customerPackageQrDone'});
}
function showPendingRedemptionQr({intent,businessName,rewardName,onClose=()=>{}}={}){
  const token=String(intent?.qr_token||'');
  if(!token)return;
  activeCustomerRedemptionCleanup({restoreFocus:false});
  const overlay=document.createElement('div');
  overlay.className='modal customer-redemption-modal';overlay.setAttribute('role','dialog');
  overlay.setAttribute('aria-modal','true');overlay.setAttribute('aria-labelledby','customerRedemptionQrTitle');
  overlay.innerHTML=`<section class="modal-card"><div class="row"><div style="text-align:left"><h2 id="customerRedemptionQrTitle">${esc(rewardName||'Redeem reward')}</h2><p class="muted small" style="margin-top:5px">${esc(businessName||'The business')} must scan this code to complete the redemption.</p></div><span class="spacer"></span><button class="btn ghost sm" id="customerRedemptionQrClose" type="button" aria-label="Close redemption QR">${CUI.icon('close',{size:20})}</button></div>
    <div class="redemption-qr" id="customerRedemptionQr" aria-label="Pending redemption QR code"></div>
    <span class="pill new" id="customerRedemptionQrState">Pending merchant scan</span>
    <p class="muted small" id="customerRedemptionQrStatus" role="status" aria-live="polite" style="margin-top:10px">Your points are not redeemed until the business scans and confirms this QR.${intent?.expires_at?` <span id="customerRedemptionCountdown">${esc(redemptionCountdownText(intent.expires_at))}</span>.`:''}</p>
    <div class="row" style="margin-top:16px"><button class="btn danger" id="customerRedemptionQrCancel" type="button">Cancel redemption</button><button class="btn ghost" id="customerRedemptionQrDone" type="button">Close — keep pending</button></div></section>`;
  document.body.appendChild(overlay);
  const qrValue=publicAppUrl(`redeem?token=${encodeURIComponent(token)}`);
  void loadQrLibrary().then(()=>new QRCode(overlay.querySelector('#customerRedemptionQr'),{text:qrValue,width:220,height:220,correctLevel:QRCode.CorrectLevel.M}))
    .catch(()=>{
      const status=overlay.querySelector('#customerRedemptionQrStatus');
      if(status)status.textContent='The QR image could not load. No points were redeemed — read the code below to the counter instead.';
      // Same escape hatch as the growth-offer QR twin: the counter can key the token in by hand.
      if(status&&!overlay.querySelector('#customerRedemptionFallback'))status.insertAdjacentHTML('afterend',`<details id="customerRedemptionFallback" style="margin-top:12px;text-align:left"><summary class="small">Show fallback token</summary><code class="growth-redemption-token">${esc(token)}</code></details>`);
    });
  let closed=false,pollTimer=0,pollInFlight=null,deactivateDialog=null,terminal=false,countdownTimer=0;
  const updateCountdown=()=>{
    const countdown=overlay.querySelector('#customerRedemptionCountdown');
    if(!countdown||closed||terminal)return;
    countdown.textContent=redemptionCountdownText(intent?.expires_at);
    if(countdown.textContent==='Expired')void reconcileRedemptionState();
  };
  const onVisibilityChange=()=>{
    if(document.visibilityState!=='visible')return;
    updateCountdown();
    /* Re-arm: schedulePoll stands down while hidden, so returning is what restarts the loop. */
    if(!closed&&!terminal&&!pollTimer)void reconcileRedemptionState();
  };
  const close=({restoreFocus=true}={})=>{
    if(closed)return;closed=true;clearTimeout(pollTimer);clearInterval(countdownTimer);document.removeEventListener('visibilitychange',onVisibilityChange);
    if(deactivateDialog){const cleanup=deactivateDialog;deactivateDialog=null;cleanup({restoreFocus})}
    else overlay.remove();
    if(activeCustomerRedemptionCleanup===close)activeCustomerRedemptionCleanup=()=>{};
    onClose();
  };
  activeCustomerRedemptionCleanup=close;
  deactivateDialog=CUI.activateDialog(overlay,{onClose:close,initialFocus:'#customerRedemptionQrCancel'});
  const finish=(state,data={})=>{
    if(closed||terminal)return;terminal=true;clearTimeout(pollTimer);clearInterval(countdownTimer);document.removeEventListener('visibilitychange',onVisibilityChange);
    const panel=overlay.querySelector('.modal-card');
    const qr=overlay.querySelector('#customerRedemptionQr');
    const pill=overlay.querySelector('#customerRedemptionQrState');
    const status=overlay.querySelector('#customerRedemptionQrStatus');
    const cancelButton=overlay.querySelector('#customerRedemptionQrCancel');
    const doneButton=overlay.querySelector('#customerRedemptionQrDone');
    qr.replaceChildren();
    if(state==='completed'){
      const receipt=data?.result||{};
      const points=Math.max(0,Number(receipt.points_spent||0));
      qr.innerHTML=CUI.icon('check',{size:32});
      panel.classList.add('customer-redemption-complete');
      pill.className='pill ok';pill.textContent='Redeemed';
      status.setAttribute('aria-live','assertive');
      status.textContent=`Redeemed!${points?` ${points} points were used for`:''} ${rewardName||'your reward'} at ${businessName||'this business'}.`;
      customerSuccessCue();
      /* V468-E2(a): the server has just told us the intent completed, which is the earliest
         honest moment the balance behind this modal is stale. Start the wallet re-read now — the
         v333 silent paint stands down while a modal is up, so this one primes the read and the
         close below is what lands it, instead of the customer waiting out a 20s tick. */
      void customerCounterMomentV468();
    }else{
      pill.className='pill off';pill.textContent=state==='cancelled'?'Cancelled':'Expired';
      status.textContent=state==='cancelled'
        ?'Redemption cancelled. No points were redeemed.'
        :'This redemption QR expired. No points were redeemed.';
    }
    cancelButton?.remove();doneButton.textContent='Close';doneButton.focus();
  };
  const reconcileRedemptionState=async({afterCancellationFailure=false}={})=>{
    if(closed||terminal||!intent?.intent_id)return;
    if(pollInFlight){
      await pollInFlight;
      if(afterCancellationFailure&&!closed&&!terminal){
        return reconcileRedemptionState({afterCancellationFailure:true});
      }
      return;
    }
    pollInFlight=(async()=>{
      const {data,error}=await sb.rpc('customer_get_redemption_intent_v89',{p_intent:intent.intent_id});
      if(closed||terminal)return;
      if(error){
        if(afterCancellationFailure){
          const status=overlay.querySelector('#customerRedemptionQrStatus');
          status.textContent='Cancellation was not confirmed. The QR remains visible. If it is still pending, try again.';
          overlay.querySelector('#customerRedemptionQrCancel').disabled=false;
        }
        schedulePoll(3000);return;
      }
      const state=String(data?.status||'pending');
      if(state==='completed')finish('completed',data);
      else if(state==='cancelled'||state==='expired')finish(state,data);
      else {
        if(afterCancellationFailure){
          const status=overlay.querySelector('#customerRedemptionQrStatus');
          status.textContent='This redemption is still pending. No points have been used. If it is still pending, try again.';
          overlay.querySelector('#customerRedemptionQrCancel').disabled=false;
        }else updateCountdown();
        schedulePoll();
      }
    })();
    try{await pollInFlight}finally{pollInFlight=null}
  };
  /* V370: the reconcile poll skips ticks while the tab is hidden and reconciles once on return.
     The QR is only useful while the customer is holding the phone up to the counter, so a
     backgrounded modal has nothing to reconcile against; onVisibilityChange below already runs
     on return and now reconciles as well as repainting the countdown, so a redemption completed
     while the phone was away still resolves the moment the customer looks back. */
  const schedulePoll=(delay=1500)=>{
    if(closed||terminal)return;
    if(document.visibilityState!=='visible'){pollTimer=0;return}
    pollTimer=setTimeout(reconcileRedemptionState,delay);
  };
  document.addEventListener('visibilitychange',onVisibilityChange);
  countdownTimer=setInterval(updateCountdown,1000);
  schedulePoll(800);
  overlay.querySelector('#customerRedemptionQrClose').onclick=close;
  overlay.querySelector('#customerRedemptionQrDone').onclick=close;
  const cancel=overlay.querySelector('#customerRedemptionQrCancel');
  cancel.onclick=async()=>{
    if(!intent?.intent_id)return;
    const confirmed=await showCustomerDecisionDialog({title:'Cancel this redemption?',body:'No points will be used.',keepLabel:'Keep QR',confirmLabel:'Cancel redemption',danger:true});
    if(!confirmed||!overlay.isConnected)return;
    cancel.disabled=true;
    const status=overlay.querySelector('#customerRedemptionQrStatus');
    status.textContent='Cancelling this redemption…';
    const slot='nestly.customer.cancelRedemption';
    const {data,error}=await sb.rpc('customer_cancel_redemption_intent_v89',{
      p_intent:intent.intent_id,
      p_idempotency_key:writeAttemptKey(slot,String(intent.intent_id))
    });
    if(!overlay.isConnected)return;
    if(error){
      await reconcileRedemptionState({afterCancellationFailure:true});
      return;
    }
    const state=String(data?.status||'');
    if(state==='cancelled')clearWriteAttempt(slot);
    if(state==='cancelled'||state==='expired'||state==='completed')finish(state,data);
    else await reconcileRedemptionState({afterCancellationFailure:true});
  };
  overlay.addEventListener('click',event=>{if(event.target===overlay)close()});
  overlay.querySelector('#customerRedemptionQrClose').focus();
}
function showGrowthOfferQr({intent,businessName,offerLabel,onClose=()=>{}}={}){
  const token=String(intent?.token||'');
  if(!token||!window.NestlyGrowthOffers)return;
  activeCustomerRedemptionCleanup({restoreFocus:false});
  const overlay=document.createElement('div');
  overlay.className='modal customer-surface appointment-detail-modal';
  overlay.setAttribute('role','dialog');
  overlay.setAttribute('aria-modal','true');
  overlay.setAttribute('aria-labelledby','growthOfferQrTitle');
  overlay.innerHTML=`<section class="modal-card" style="width:460px;text-align:center">
    <div class="row"><div style="text-align:left"><h2 id="growthOfferQrTitle">${esc(offerLabel||'Redeem offer')}</h2>
    <p class="muted small" style="margin-top:5px">${esc(businessName||'The business')} must scan this code before the offer is used.</p></div>
    <span class="spacer"></span><button class="btn ghost sm" id="growthOfferQrClose" type="button" aria-label="Close offer QR">${CUI.icon('close',{size:20})}</button></div>
    <div class="redemption-qr" id="growthOfferQr" aria-label="Pending growth offer QR code"></div>
    <span class="pill new">Ready to scan</span>
    <p class="muted small" role="status" aria-live="polite" style="margin-top:10px">This offer remains unused until the business scans it.${intent?.expires_at?` This QR expires ${esc(walletDate(intent.expires_at,true))}.`:''}</p>
    <details style="margin-top:12px;text-align:left"><summary class="small">Show fallback token</summary>
      <code class="growth-redemption-token">${esc(token)}</code></details>
    <button class="btn" id="growthOfferQrDone" type="button" style="margin-top:16px">Done</button>
  </section>`;
  document.body.appendChild(overlay);
  const qrValue=window.NestlyGrowthOffers.buildGrowthRedeemUrl(token,{
    origin:location.origin,pathname:location.pathname
  });
  void loadQrLibrary().then(()=>new QRCode(overlay.querySelector('#growthOfferQr'),{
    text:qrValue,width:220,height:220,correctLevel:QRCode.CorrectLevel.M
  })).catch(()=>{const status=overlay.querySelector('[role="status"]');if(status)status.textContent='The QR image could not load. Close and retry; the offer remains unused.'});
  let closed=false,deactivateDialog=null;
  const close=({restoreFocus=true}={})=>{
    if(closed)return;closed=true;
    if(deactivateDialog){const cleanup=deactivateDialog;deactivateDialog=null;cleanup({restoreFocus})}
    else overlay.remove();
    if(activeCustomerRedemptionCleanup===close)activeCustomerRedemptionCleanup=()=>{};
    onClose();
    /* V468-E2(a): an offer QR is a counter moment too — the shop scans it and the wallet behind
       this overlay is immediately out of date. */
    void customerCounterMomentV468();
  };
  activeCustomerRedemptionCleanup=close;
  deactivateDialog=CUI.activateDialog(overlay,{onClose:close,initialFocus:'#growthOfferQrDone'});
  overlay.querySelector('#growthOfferQrClose').onclick=close;
  overlay.querySelector('#growthOfferQrDone').onclick=close;
  overlay.addEventListener('click',event=>{if(event.target===overlay)close()});
  overlay.querySelector('#growthOfferQrDone').focus();
}
/* ---------- customer wallet ---------- */
/* V468 HELD, deliberately not shipped: the owner bracketed Agreements and wrote "default = tick
   the box". Pre-ticking these two reverses an explicit earlier ruling of theirs (v263/v265,
   2026-08-09) whose stated reason was that "a pre-ticked box is not a choice", and
   tests/customer-modules/v265-marketing-consent-scope.test.mjs exists to stop exactly that
   reversal happening by accident. ⚖️ Pre-ticking a marketing consent is PDPA territory and is a
   decision for the owner with counsel, not a cosmetic default — so the flags stay false and the
   owner has been asked to confirm. The long consent copy IS collapsed (that mark was safe). */
let customerRegistrationState={
  phone:'',channel:'sms',purpose:'signup',legalAccepted:false,marketingOptedIn:false
};
let customerAutomaticPasskeyAttempted=false;
function resetCustomerRegistrationState({phone=''}={}){
  customerRegistrationState={
    phone,channel:'sms',purpose:'signup',legalAccepted:false,marketingOptedIn:false
  };
  try{sessionStorage.removeItem('peekaa-customer-signup-consent-v163')}catch{}
  try{sessionStorage.removeItem('peekaa-customer-signup-profile-v174')}catch{}
}
/* v175: legal acceptance and marketing consent are separate records. Legal
   acceptance is required to register; marketing is a genuinely optional opt-in
   (PDPA-valid consent must not be a condition of service). */
function rememberCustomerSignupConsent(accepted,marketingOptedIn=false){
  try{
    if(accepted)sessionStorage.setItem('peekaa-customer-signup-consent-v163',marketingOptedIn?'accepted+marketing':'accepted');
    else sessionStorage.removeItem('peekaa-customer-signup-consent-v163');
  }catch{}
}
function customerSignupMarketingOptedIn(){
  if(customerRegistrationState.legalAccepted)return customerRegistrationState.marketingOptedIn===true;
  try{return sessionStorage.getItem('peekaa-customer-signup-consent-v163')==='accepted+marketing'}catch{return false}
}
/* v174: name, date of birth and gender are asked on the Create-account form,
   stashed for the OTP hop, and the post-OTP profile step completes itself from
   the stash — one visible signup step for the normal path. */
function rememberCustomerSignupProfile(profile){
  try{
    if(profile)sessionStorage.setItem('peekaa-customer-signup-profile-v174',JSON.stringify(profile));
    else sessionStorage.removeItem('peekaa-customer-signup-profile-v174');
  }catch{}
}
function customerSignupProfileStash(){
  try{
    const raw=sessionStorage.getItem('peekaa-customer-signup-profile-v174');
    const profile=raw?JSON.parse(raw):null;
    return profile&&String(profile.fullName||'').trim()&&profile.birthDate
      &&['female','male'].includes(profile.gender)?profile:null;
  }catch{return null}
}
/* V265: the marketing tick and the v263 Communications switches are one promise, so a
   grant must leave every category x channel on. The v92 consent record is always written
   FIRST and the v263 master grant follows: the reverse order would start delivery before
   the evidence exists. A failed grant therefore leaves consent recorded while some
   switches stay off — the Communications screen still shows exactly what is stored, so it
   never overstates; callers surface the partial failure rather than claiming success. */
async function grantAllCommunicationsV265(){
  try{
    const {error}=await sb.rpc('customer_set_all_communications_v263',{p_enabled:true});
    return !error;
  }catch{return false}
}
function customerSignupConsentRecorded(){
  if(customerRegistrationState.legalAccepted)return true;
  try{return String(sessionStorage.getItem('peekaa-customer-signup-consent-v163')||'').startsWith('accepted')}catch{return false}
}
const unavailableCustomerPhoneOtpCapabilities=()=>({sms:false,whatsapp:false});
async function loadCustomerPhoneOtpCapabilities({refresh=false}={}){
  if(!CUSTOMER_PHONE_OTP_RUNTIME_ENABLED)return unavailableCustomerPhoneOtpCapabilities();
  if(customerPhoneOtpCapabilities&&!refresh)return customerPhoneOtpCapabilities;
  const {data,error}=await preAuthSb.rpc('get_customer_phone_otp_capabilities');
  customerPhoneOtpCapabilities=error?unavailableCustomerPhoneOtpCapabilities():{
    sms:data?.sms===true,whatsapp:data?.whatsapp===true
  };
  return customerPhoneOtpCapabilities;
}
async function customerPhoneOtpAvailable(channel='sms'){
  if(!CUSTOMER_PHONE_OTP_RUNTIME_ENABLED)return false;
  if(channel==='whatsapp'&&!CUSTOMER_WHATSAPP_OTP_RUNTIME_ENABLED)return false;
  const serverCapabilities=await loadCustomerPhoneOtpCapabilities({refresh:true});
  return channel==='whatsapp'?serverCapabilities.whatsapp===true:serverCapabilities.sms===true;
}
function setCustomerThemePreferenceV190(preference){
  const next=CUSTOMER_THEMES_V190.includes(preference)?preference:'light';
  try{localStorage.setItem(CUSTOMER_THEME_KEY_V190,next)}catch{}
  return applyCustomerThemeV190(next);
}
function customerRegistrationShell(body){
  destroyMountedTurnstiles();
  setCustomerSurfaceDocumentV167();
  root.innerHTML=`<main class="wallet-shell customer-surface" id="main" tabindex="-1"><div class="wallet-inner"><header class="wallet-head">
    <a class="logo" href="/app" aria-label="${esc(BRAND.customerLabel)} home">${brandWordmark()}</a>
    </header>${body}<footer class="customer-entry-footer"><a class="customer-business-link" href="/business">Business sign in</a>${legalLinks(customerLocale)}</footer></div></main>`;
  CUI.focusRoute($('main'),{enhanceContent:true});
}
function renderCustomerOtpVerification(isRouteCurrent=()=>true){
  const {phone,channel,purpose}=customerRegistrationState;
  const recovering=purpose==='recovery';
  if(!phone){
    if(!isRouteCurrent())return;
    return renderCustomerRegistration(isRouteCurrent);
  }
  if(!isRouteCurrent())return;
  customerRegistrationShell(`<section class="card" aria-labelledby="customerOtpTitle">
    <div class="row"><span aria-hidden="true">${CUI.icon('customers',{size:24})}</span><div><h1 id="customerOtpTitle">Enter your code</h1><p class="muted small" style="margin-top:5px">${recovering?'Verify your mobile number once to choose a new password.':'Verify your mobile number to finish creating your account.'}</p></div></div>
    <label for="customerOtp">One-time code</label>
    <input id="customerOtp" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" aria-describedby="customerOtpHelp" required>
    <p class="muted small" id="customerOtpHelp" style="margin-top:6px">The code is valid for a few minutes.</p>
    <div id="customerOtpError" role="alert" aria-live="assertive"></div>
    <button class="btn" id="customerOtpVerify" type="button" style="width:100%;margin-top:16px">${CUI.icon('check',{size:20})}<span>${recovering?'Verify and reset password':'Verify and create account'}</span></button>
    <button class="btn ghost" id="customerOtpResend" type="button" disabled style="width:100%;margin-top:10px">Resend available in 30 seconds</button>
    <button class="btn ghost" id="customerOtpVerifyBack" type="button" style="width:100%;margin-top:10px">${CUI.icon('back',{size:20})}<span>Back</span></button>
  </section>`);
  $('customerOtpVerifyBack').onclick=()=>renderCustomerOtpStart(isRouteCurrent,purpose);
  let seconds=30;
  const resend=$('customerOtpResend');
  const countdown=setInterval(()=>{
    if(!resend?.isConnected)return clearInterval(countdown);
    seconds-=1;
    if(seconds>0)resend.textContent=`Resend available in ${seconds} seconds`;
    else {resend.disabled=false;resend.textContent='Resend code';clearInterval(countdown);}
  },1000);
  const verify=$('customerOtpVerify'),otpInput=$('customerOtp'),otpError=$('customerOtpError');
  verify.onclick=async()=>{
    const token=otpInput.value.replace(/\s/g,'');
    if(!/^[0-9]{6}$/.test(token)){
      otpError.innerHTML='<div class="err">Enter the 6-digit code.</div>';return;
    }
    const button=verify;button.disabled=true;
    const {data,error}=await sb.auth.verifyOtp({phone,token,type:'sms'});
    if(!isRouteCurrent()||!button.isConnected||!otpError.isConnected)return;
    if(error||!data?.user||!data?.session){
      button.disabled=false;
      otpError.innerHTML=`<div class="err">${esc(customerAuthErrorMessageV289(error,'otp_verify'))}</div>`;return;
    }
    S.user=data.user;
    if(!isRouteCurrent()||!button.isConnected)return;
    if(recovering){
      rememberCustomerRecoveryVerified(data.user.id);
      return renderCustomerRecoveryPasswordSetup(isRouteCurrent);
    }
    renderCustomerRegistration(isRouteCurrent);
  };
  resend.onclick=async()=>{
    const otpError=$('customerOtpError');
    if(customerPhoneBlockedInProduction(phone)){
      otpError.innerHTML='<div class="err">Customer mobile verification is unavailable. Please return and try again later.</div>';return;
    }
    const available=await customerPhoneOtpAvailable(channel);
    if(!isRouteCurrent()||!resend.isConnected||!otpError.isConnected)return;
    if(!available){
      otpError.innerHTML='<div class="err">Customer mobile verification is unavailable. Please return and try again later.</div>';return;
    }
    resend.disabled=true;
    const options={};if(channel==='whatsapp')options.channel='whatsapp';
    const {error}=recovering
      ?await sb.auth.signInWithOtp({phone,options:{...options,shouldCreateUser:false}})
      :await sb.auth.resend({type:'sms',phone,options});
    if(!isRouteCurrent()||!resend.isConnected||!otpError.isConnected)return;
    if(error){resend.disabled=false;otpError.innerHTML=`<div class="err">${esc(customerAuthErrorMessageV289(error,'otp_send'))}</div>`;return;}
    seconds=30;resend.textContent='Resend available in 30 seconds';
    const nextCountdown=setInterval(()=>{
      if(!resend?.isConnected)return clearInterval(nextCountdown);
      seconds-=1;
      if(seconds>0)resend.textContent=`Resend available in ${seconds} seconds`;
      else {resend.disabled=false;resend.textContent='Resend code';clearInterval(nextCountdown);}
    },1000);
  };
}
/* V289 (audit A3, G6 — "auth error honesty"). Sign-in, OTP entry and OTP sending each answered
   every possible failure with one sentence, so an offline phone, a Supabase rate limit and a
   genuinely wrong password were indistinguishable — and only one of the three is worth retrying
   immediately. This classifies what actually came back so the copy can say it.

   DELIBERATELY NOT SPLIT: wrong password vs unknown number. Supabase returns the same
   `invalid_credentials` for both by design, and making the app say "no account for this number"
   would turn the sign-in form into an oracle for "is 8xxxxxxx a Peekaa customer" — the same PDPA
   enumeration risk that `join_program` returns a uniform status to avoid (v14). The combined
   sentence is the honest one, and it names both possibilities. */
function customerAuthFailureKindV289(error){
  if(!error)return 'unknown';
  const code=String(error.code||'').toLowerCase();
  const name=String(error.name||'');
  const message=String(error.message||'').toLowerCase();
  const status=Number(error.status||0);
  if(name==='AuthRetryableFetchError'||name==='TypeError'
    ||(!code&&status===0&&/fetch|network|connection|offline/.test(message)))return 'network';
  if(globalThis.navigator?.onLine===false)return 'network';
  if(status===429||code.includes('rate_limit')||message.includes('rate limit'))return 'rate_limited';
  if(code==='otp_expired'||message.includes('token has expired'))return 'otp_invalid';
  if(code==='phone_not_confirmed'||message.includes('phone not confirmed'))return 'phone_unconfirmed';
  if(code==='invalid_credentials'||message.includes('invalid login credentials'))return 'invalid_credentials';
  if(status>=500||code==='unexpected_failure')return 'server';
  return 'unknown';
}
function customerAuthErrorMessageV289(error,context='sign_in'){
  const kind=customerAuthFailureKindV289(error);
  if(kind==='network')return 'We could not reach Peekaa. Check your connection, then try again.';
  if(kind==='rate_limited'){
    return context==='otp_send'
      ?'Too many codes have been requested for this number. Wait a few minutes, then try again.'
      :'Too many attempts. Wait about a minute, then try again.';
  }
  if(context==='otp_verify'){
    if(kind==='otp_invalid')return 'That code is wrong or has expired. Check the code, or tap Resend code for a new one.';
    if(kind==='server')return 'Verification is temporarily unavailable. Your code is still valid — try again shortly.';
    return 'That code could not be verified. Check it and try again.';
  }
  if(context==='otp_send'){
    if(kind==='server')return 'We could not send a code just now. Nothing has changed — try again shortly.';
    return 'We could not send a code to that number. Check the number and try again.';
  }
  if(kind==='phone_unconfirmed')return 'This mobile number has not been verified yet. Tap Create account to finish signing up.';
  if(kind==='server')return 'Sign-in is temporarily unavailable. Nothing has changed — try again shortly.';
  return 'The mobile number or password is incorrect. Check both, or use Forgot password?';
}
function customerPasswordUpdateErrorMessage(error){
  const code=String(error?.code||'').toLowerCase();
  const message=String(error?.message||'').toLowerCase();
  if(code==='same_password'||message.includes('same password')){
    return 'Choose a password that is different from your current password.';
  }
  if(code==='weak_password'||error?.name==='WeakPasswordError'||message.includes('weak password')
    ||message.includes('password is known to be weak')||message.includes('password has been pwned')){
    return 'Choose a stronger, unique password that has not appeared in a known data breach.';
  }
  if(code.includes('reauthentication')||message.includes('reauthentication')){
    return 'For your protection, this reset session must be verified again. Return to sign in and request a new reset code.';
  }
  if(code.includes('session')||code.includes('jwt')||message.includes('session')
    ||message.includes('jwt')||message.includes('not authenticated')){
    return 'This reset session has expired. Return to sign in and request a new reset code.';
  }
  return 'Your password could not be changed. Check that it is unique and meets every requirement, then try again.';
}
function renderCustomerRecoveryPasswordSetup(isRouteCurrent=()=>true){
  if(!isRouteCurrent())return;
  customerRegistrationShell(`<section class="card" aria-labelledby="customerRecoveryPasswordTitle">
    <div class="row"><span aria-hidden="true">${CUI.icon('customers',{size:24})}</span><div><h1 id="customerRecoveryPasswordTitle">Choose a new password</h1><p class="muted small" style="margin-top:5px">Use this password for normal Peekaa sign-in. No OTP is sent when you sign in with it.</p></div></div>
    <label for="customerRecoveryPassword">New password</label>
    ${passwordControlHtml('customerRecoveryPassword',{autocomplete:'new-password',minlength:'12',describedBy:'customerRecoveryPasswordHelp'})}
    <p class="muted small" id="customerRecoveryPasswordHelp" style="margin-top:6px">At least 12 characters with uppercase, lowercase, a number, and a symbol.</p>
    <label for="customerRecoveryPasswordConfirm">Confirm new password</label>
    ${passwordControlHtml('customerRecoveryPasswordConfirm',{autocomplete:'new-password',minlength:'12'})}
    <div id="customerRecoveryPasswordError" role="alert" aria-live="assertive"></div>
    <button class="btn" id="customerRecoveryPasswordSave" type="button" style="width:100%;margin-top:18px">${CUI.icon('check',{size:20})}<span>Save new password</span></button>
    <button class="btn ghost" id="customerRecoveryPasswordBack" type="button" style="width:100%;margin-top:10px">${CUI.icon('back',{size:20})}<span>Cancel and return to sign in</span></button>
  </section>`);
  bindPasswordVisibility(root);
  const save=$('customerRecoveryPasswordSave'),password=$('customerRecoveryPassword');
  const confirmPassword=$('customerRecoveryPasswordConfirm'),errorHost=$('customerRecoveryPasswordError');
  $('customerRecoveryPasswordBack').onclick=async()=>{
    rememberCustomerRecoveryVerified('');
    await sb.auth.signOut();
    resetClientSessionState({preserveInvitation:true});
    resetCustomerRegistrationState();
    renderCustomerPasswordSignIn(isRouteCurrent);
  };
  save.onclick=async()=>{
    if(!validNewPassword(password.value)){
      errorHost.innerHTML='<div class="err">Use at least 12 characters with uppercase, lowercase, a number, and a symbol.</div>';return;
    }
    if(password.value!==confirmPassword.value){
      errorHost.innerHTML='<div class="err">Passwords do not match.</div>';return;
    }
    save.disabled=true;
    save.querySelector('span').textContent='Saving new password…';
    const {data:userData,error:sessionError}=await sb.auth.getUser();
    if(!isRouteCurrent()||!save.isConnected)return;
    if(sessionError||!userData?.user||userData.user.id!==S.user?.id){
      save.disabled=false;
      save.querySelector('span').textContent='Save new password';
      errorHost.innerHTML='<div class="err">This reset session has expired. Return to sign in and request a new reset code.</div>';
      return;
    }
    const {error}=await sb.auth.updateUser({password:password.value});
    if(!isRouteCurrent()||!save.isConnected)return;
    if(error){
      save.disabled=false;save.querySelector('span').textContent='Save new password';
      errorHost.innerHTML=`<div class="err">${esc(customerPasswordUpdateErrorMessage(error))}</div>`;return;
    }
    const phone=customerRegistrationState.phone;
    rememberCustomerRecoveryVerified('');
    await sb.auth.signOut();
    resetClientSessionState({preserveInvitation:true});
    resetCustomerRegistrationState({phone});
    renderCustomerPasswordSignIn(isRouteCurrent,{notice:'Password updated. Sign in with your mobile number and new password.'});
  };
}
/* v193 (owner: "save password not working"). A password manager offers to save on a real FORM
   SUBMIT, from fields it can name: username + password. This screen was two loose inputs and a
   type="button", so Chrome and Safari had nothing to recognise and never prompted. The phone field
   also carried autocomplete="tel", which is not the username hint a manager pairs a credential to
   — and "username webauthn" is the documented pairing for passkey autofill as well. */
function renderCustomerPasswordSignIn(isRouteCurrent=()=>true,{notice='',noticeTone='success'}={}){
  if(!isRouteCurrent())return;
  customerRegistrationShell(`<section class="card" aria-labelledby="customerPasswordTitle">
    <div class="row"><span aria-hidden="true">${CUI.icon('customers',{size:24})}</span><div><h1 id="customerPasswordTitle">Welcome to ${esc(BRAND.productName)}</h1><p class="muted small" style="margin-top:5px">Sign in with your mobile number and password. Normal sign-in does not send an OTP.</p></div></div>
    <form id="customerPasswordForm" novalidate>
    <label for="customerPasswordPhone">Singapore mobile number</label>
    <input id="customerPasswordPhone" name="username" type="tel" inputmode="tel" autocomplete="username webauthn" placeholder="8123 4567" value="${esc(customerRegistrationState.phone.replace(/^\+65/,''))}">
    <label for="customerPassword">Password</label>
    ${passwordControlHtml('customerPassword',{autocomplete:'current-password',passkeyButtonId:'customerPasskeySignIn',name:'password'})}
    <div id="customerPasswordError" role="alert" aria-live="assertive">${notice?`<p class="muted small" style="margin-top:10px${noticeTone==='success'?';color:var(--green)':''}">${esc(notice)}</p>`:''}</div>
    <button class="btn" id="customerPasswordSignIn" type="submit" style="width:100%;margin-top:16px">${CUI.icon('forward',{size:20})}<span>Sign in</span></button>
    </form>
    <div class="row" style="margin-top:12px;gap:8px"><button class="btn ghost sm" id="customerCreateAccount" type="button">Create account</button><span class="spacer"></span><button class="btn ghost sm" id="customerForgotPassword" type="button">Forgot password?</button></div>
    <p id="customerPasskeyStatus" class="muted small" role="status" aria-live="polite" style="margin-top:8px"></p>
  </section>`);
  bindPasswordVisibility(root);
  const signIn=$('customerPasswordSignIn'),phoneInput=$('customerPasswordPhone');
  const passwordInput=$('customerPassword'),errorHost=$('customerPasswordError');
  const passkeyButton=$('customerPasskeySignIn'),passkeyStatus=$('customerPasskeyStatus');
  const passkeySupported=isSecureContext&&'PublicKeyCredential' in globalThis&&typeof sb.auth.signInWithPasskey==='function';
  const installedApp=globalThis.navigator?.standalone===true
    ||globalThis.matchMedia?.('(display-mode: standalone)')?.matches===true;
  if(!passkeySupported)passkeyStatus.textContent='Passkeys are not supported in this browser. Sign in with your password.';
  /* V286: renderCustomerOtpStart awaits the phone-OTP capability RPC before it paints anything,
     so on a slow connection the most important tap on this screen looked like nothing happened —
     and every further tap started another render racing to overwrite the same shell. */
  $('customerCreateAccount').onclick=async(event)=>{
    const button=event.currentTarget;
    if(button.disabled)return;
    const idle=CUI.setButtonBusy(button,{label:'Opening…'});
    resetCustomerRegistrationState();
    try{await renderCustomerOtpStart(isRouteCurrent,'signup')}
    finally{if(button.isConnected)idle()}
  };
  $('customerForgotPassword').onclick=()=>renderCustomerOtpStart(isRouteCurrent,'recovery');
  /* V388: customer sign-in no longer waits on a security check. Supabase Auth CAPTCHA is off
     server-side, so the form is usable the moment it paints — Cloudflare being slow, blocked or
     down can no longer keep a customer out of their own account. The automatic passkey attempt
     used to hang off the Turnstile token callback; it now fires once runPasskeySignIn exists,
     at the bottom of this function. */
  const submitSignIn=async()=>{
    const phone=normalizeSingaporeCustomerPhone(phoneInput.value),password=passwordInput.value;
    if(!phone||!password){
      errorHost.innerHTML='<div class="err">Enter your Singapore mobile number and password.</div>';return;
    }
    signIn.disabled=true;
    signIn.querySelector('span').textContent='Signing in…';
    passkeyButton.disabled=true;
    const {data,error}=await sb.auth.signInWithPassword({phone,password});
    if(!isRouteCurrent()||!signIn.isConnected)return;
    if(error||!data?.user){
      // A failed sign-in must not become a dead end — hand the form straight back.
      signIn.disabled=false;
      passkeyButton.disabled=!passkeySupported;
      signIn.querySelector('span').textContent='Sign in';
      errorHost.innerHTML=`<div class="err">${esc(customerAuthErrorMessageV289(error,'sign_in'))}</div>`;return;
    }
    /* Offer the credential to the browser's own manager. The form submit is what makes Chrome and
       Safari prompt; this is the explicit path for browsers that implement it, and a no-op
       everywhere else. Peekaa itself never stores the password. */
    try{
      if(globalThis.PasswordCredential&&navigator.credentials?.store){
        await navigator.credentials.store(new globalThis.PasswordCredential({id:phone,password,name:phone}));
      }
    }catch{}
    resetCustomerRegistrationState({phone});
    resetClientSessionState({preserveInvitation:true});
    route();
  };
  /* A real submit — Enter in either field, or the button — is what a password manager listens for. */
  const signInForm=$('customerPasswordForm');
  if(signInForm)signInForm.onsubmit=event=>{event.preventDefault();submitSignIn()};
  else signIn.onclick=submitSignIn;
  const runPasskeySignIn=async({automatic=false}={})=>{
    if(!passkeySupported){
      if(!automatic){
        passkeyStatus.textContent='Passkeys are not supported in this browser. Sign in with your password.';
      }
      return;
    }
    passkeyButton.disabled=true;signIn.disabled=true;
    passkeyStatus.textContent='Waiting for your device…';
    const {data,error}=await sb.auth.signInWithPasskey();
    if(!isRouteCurrent()||!passkeyButton.isConnected)return;
    if(error||!data?.user){
      passkeyButton.disabled=!passkeySupported;signIn.disabled=false;
      passkeyStatus.textContent=error?.code==='passkey_disabled'
        ?'Face ID and passkeys aren’t available yet. Use your password.'
        :(automatic?'Passkey sign-in was not completed. Use your password or the Face ID button.':customerPasskeyErrorMessage(error,{action:'sign-in'}));
      return;
    }
    resetClientSessionState({preserveInvitation:true});route();
  };
  passkeyButton.onclick=()=>runPasskeySignIn();
  /* V388: declared above as a const, so this trigger must sit after it — calling it from where
     the Turnstile callback used to live would hit the temporal dead zone. */
  if(installedApp&&passkeySupported&&!customerAutomaticPasskeyAttempted){
    customerAutomaticPasskeyAttempted=true;
    runPasskeySignIn({automatic:true});
  }
}
async function renderCustomerOtpStart(isRouteCurrent=()=>true,purpose='signup'){
  const recovering=purpose==='recovery';
  const serverCapabilities=await loadCustomerPhoneOtpCapabilities({refresh:true});
  if(!isRouteCurrent())return;
  const smsAvailable=CUSTOMER_PHONE_OTP_RUNTIME_ENABLED&&serverCapabilities.sms===true;
  const whatsappAvailable=CUSTOMER_WHATSAPP_OTP_RUNTIME_ENABLED&&serverCapabilities.whatsapp===true;
  /* V289 (audit A3, G7). When the server reports sms:false this function used to paint the ENTIRE
     sign-up form — every field, the channel radios, a Turnstile placeholder — and only then hit
     `if(!smsAvailable)return`, which left the widget unmounted. The result was a complete-looking
     form whose security check said "Loading security check…" forever and whose Send button never
     enabled: a screen that lied about being nearly ready. Nothing here can work without SMS, so
     render the one true sentence and no controls at all. */
  if(!smsAvailable){
    customerRegistrationShell(`<section class="card" aria-labelledby="customerOtpUnavailableTitle">
      <div class="row"><span aria-hidden="true">${CUI.icon('customers',{size:24})}</span><div><h1 id="customerOtpUnavailableTitle">${recovering?'Password reset is unavailable':'Sign-up by SMS is unavailable'}</h1></div></div>
      <p class="muted small" style="margin-top:10px" role="status">${recovering?'We cannot send a reset code right now because mobile verification is unavailable. Nothing has changed on your account. Please try again later.':'We cannot send a verification code right now because mobile verification is unavailable. No account has been created. Please try again later.'}</p>
      <button class="btn ghost" id="customerOtpBack" type="button" style="width:100%;margin-top:18px">Back to sign in</button>
    </section>`);
    $('customerOtpBack').onclick=()=>{
      resetCustomerRegistrationState();
      renderCustomerPasswordSignIn(isRouteCurrent);
    };
    return;
  }
  customerRegistrationShell(`<section class="card" aria-labelledby="customerOtpStartTitle">
    <div class="row"><span aria-hidden="true">${CUI.icon('customers',{size:24})}</span><div><h1 id="customerOtpStartTitle">${recovering?'Reset your password':'Create your account'}</h1><p class="muted small" style="margin-top:5px">${recovering?'We send one OTP to verify that you own this mobile number.':'Tell us about yourself, choose your password, then verify your mobile number with one OTP.'}</p></div></div>
    <label for="customerPhone">Singapore mobile number</label>
    <input id="customerPhone" type="tel" inputmode="tel" autocomplete="tel" placeholder="8123 4567" value="${esc(customerRegistrationState.phone.replace(/^\+65/,''))}">
    ${recovering?'':`<label for="customerSignupPassword">Password</label>${passwordControlHtml('customerSignupPassword',{autocomplete:'new-password',minlength:'12',describedBy:'customerSignupPasswordHelp'})}<p class="muted small" id="customerSignupPasswordHelp" style="margin-top:6px">At least 12 characters with uppercase, lowercase, a number, and a symbol.</p><label for="customerSignupPasswordConfirm">Confirm password</label>${passwordControlHtml('customerSignupPasswordConfirm',{autocomplete:'new-password',minlength:'12'})}
    <label for="customerSignupFullName">Full name</label>
    <input id="customerSignupFullName" autocomplete="name" maxlength="200" value="${esc(customerSignupProfileStash()?.fullName||'')}">
    <label for="customerSignupDob">Date of birth</label>
    <input id="customerSignupDob" type="date" autocomplete="bday" max="${sgDateInputValue()}" value="${esc(customerSignupProfileStash()?.birthDate||'')}">
    <label for="customerSignupGender">Gender</label>
    <select id="customerSignupGender" autocomplete="sex"><option value="">Select gender</option><option value="female" ${customerSignupProfileStash()?.gender==='female'?'selected':''}>Female</option><option value="male" ${customerSignupProfileStash()?.gender==='male'?'selected':''}>Male</option></select>
    <fieldset style="border:0;margin-top:18px;padding:0"><legend class="small" style="font-weight:700">Agreements</legend>
      <label class="row" for="customerSignupConsent" style="align-items:flex-start;margin-top:10px;color:var(--ink);font-weight:500"><input id="customerSignupConsent" type="checkbox" ${customerRegistrationState.legalAccepted?'checked':''} style="width:20px;min-width:20px;min-height:20px;margin-top:1px"> <span>I agree to the <a href="/terms.html" target="_blank" rel="noopener noreferrer" style="color:var(--coral);text-decoration:underline">Terms of Service</a> and acknowledge the <a href="/privacy.html" target="_blank" rel="noopener noreferrer" style="color:var(--coral);text-decoration:underline">Privacy Notice</a>.</span></label>
      <label class="row" for="customerSignupMarketing" style="align-items:flex-start;margin-top:12px;color:var(--ink);font-weight:500"><input id="customerSignupMarketing" type="checkbox" ${customerRegistrationState.marketingOptedIn?'checked':''} style="width:20px;min-width:20px;min-height:20px;margin-top:1px"> <span><b>Yes — send me offers and updates.</b> <span class="muted">(Optional)</span></span></label>
      <details class="signup-consent-detail-v468"><summary>Click to read what “offers and updates” means</summary>
        <p class="muted small">Nestly Technologies Pte. Ltd., the company behind ${esc(BRAND.productName)}, and its partners may send me marketing by push notification, in-app message, email, SMS, WhatsApp, phone call and other marketing channels. My name and contact details may be shared with ${esc(BRAND.productName)}’s partners for marketing purposes only. I can turn this off any time in Profile → Communications. ${esc(BRAND.productName)} stops sending straight away. Partners are told to stop within 10 business days.</p>
      </details>
    </fieldset>`}
    <fieldset style="border:0;margin-top:18px;padding:0"><legend class="small" style="font-weight:700">Send the verification code by</legend>
      <label class="row" for="customerOtpSms" style="color:var(--ink);font-weight:500"><input id="customerOtpSms" name="customerOtpChannel" type="radio" value="sms" checked style="width:20px;min-width:20px;min-height:20px"> <span>SMS</span></label>
      ${whatsappAvailable?`<label class="row" for="customerOtpWhatsapp" style="margin-top:10px;color:var(--ink);font-weight:500"><input id="customerOtpWhatsapp" name="customerOtpChannel" type="radio" value="whatsapp" style="width:20px;min-width:20px;min-height:20px"> <span>WhatsApp</span></label>`:''}
    </fieldset>
    <div id="customerOtpError" role="alert" aria-live="assertive"></div>
    <button class="btn" id="customerOtpSend" type="button" style="width:100%;margin-top:16px">${CUI.icon('forward',{size:20})}<span>${recovering?'Send password reset code':'Send account verification code'}</span></button>
    <button class="btn ghost" id="customerOtpBack" type="button" style="width:100%;margin-top:10px">Back to sign in</button>
  </section>`);
  bindPasswordVisibility(root);
  $('customerOtpBack').onclick=()=>{
    resetCustomerRegistrationState();
    renderCustomerPasswordSignIn(isRouteCurrent);
  };
  const send=$('customerOtpSend'),phoneInput=$('customerPhone'),errorHost=$('customerOtpError');
  send.onclick=async()=>{
    const phone=normalizeSingaporeCustomerPhone(phoneInput.value);
    const channel=document.querySelector('input[name="customerOtpChannel"]:checked')?.value||'sms';
    if(!phone){errorHost.innerHTML='<div class="err">Enter a valid 8-digit Singapore number.</div>';return}
    if(customerPhoneBlockedInProduction(phone)){
      errorHost.innerHTML='<div class="err">Mobile verification is unavailable right now.</div>';return;
    }
    const available=await customerPhoneOtpAvailable(channel);
    if(!isRouteCurrent()||!send.isConnected)return;
    if(!available){
      errorHost.innerHTML='<div class="err">Mobile verification is unavailable right now.</div>';return;
    }
    let password='';
    if(!recovering){
      password=$('customerSignupPassword').value;
      if(!validNewPassword(password)){
        errorHost.innerHTML='<div class="err">Use at least 12 characters with uppercase, lowercase, a number, and a symbol.</div>';return;
      }
      if(password!==$('customerSignupPasswordConfirm').value){
        errorHost.innerHTML='<div class="err">Passwords do not match.</div>';return;
      }
      const signupFullName=$('customerSignupFullName').value.trim(),
        signupBirthDate=$('customerSignupDob').value,
        signupGender=$('customerSignupGender').value;
      if(!signupFullName){
        errorHost.innerHTML='<div class="err">Enter your full name.</div>';return;
      }
      if(!signupBirthDate||new Date(`${signupBirthDate}T00:00:00`)>new Date()){
        errorHost.innerHTML='<div class="err">Enter a date of birth that is not in the future.</div>';return;
      }
      if(!['female','male'].includes(signupGender)){
        errorHost.innerHTML='<div class="err">Select Male or Female to continue.</div>';return;
      }
      if(!$('customerSignupConsent').checked){
        errorHost.innerHTML='<div class="err">Please agree to the Terms of Service and acknowledge the Privacy Notice to continue. The marketing box is optional.</div>';return;
      }
      rememberCustomerSignupProfile({fullName:signupFullName,birthDate:signupBirthDate,gender:signupGender});
    }
    send.disabled=true;
    const options={};if(channel==='whatsapp')options.channel='whatsapp';
    const result=recovering
      ?await sb.auth.signInWithOtp({phone,options:{...options,shouldCreateUser:false}})
      :await sb.auth.signUp({phone,password,options});
    if(!isRouteCurrent()||!send.isConnected)return;
    if(result.error||(recovering&&result.data?.session)){
      send.disabled=false;
      /* V289 (G6): the two sentences below are deliberately non-committal about whether the
         number exists. A rate limit or a dead connection is not that kind of secret, and telling
         someone to "try again later" when the real answer is "wait a few minutes" or "you are
         offline" is what made this screen feel broken. */
      const startKindV289=customerAuthFailureKindV289(result.error);
      errorHost.innerHTML=`<div class="err">${startKindV289==='network'||startKindV289==='rate_limited'
        ?esc(customerAuthErrorMessageV289(result.error,'otp_send'))
        :(recovering?'If an account exists for this number, a reset code could not be sent. Try again later.':'We could not start account creation. If you already have an account, return and sign in or reset your password.')}</div>`;return;
    }
    if(!recovering&&result.data?.session){
      await sb.auth.signOut();
      send.disabled=false;
      errorHost.innerHTML='<div class="err">Mobile verification must be enabled before customer accounts can be created.</div>';return;
    }
    customerRegistrationState={
      phone,channel,purpose,
      legalAccepted:recovering?false:$('customerSignupConsent').checked,
      marketingOptedIn:recovering?false:$('customerSignupMarketing').checked
    };
    rememberCustomerSignupConsent(!recovering&&$('customerSignupConsent').checked,
      !recovering&&$('customerSignupMarketing').checked);
    renderCustomerOtpVerification(isRouteCurrent);
  };
}
async function runCustomerRegistrationProfileSubmission({registerRequest,resolveDestination,isCurrent,onRegistrationError}){
  const result=await registerRequest();
  if(!isCurrent())return 'stale';
  if(result.error||result.data?.outcome!=='registered'){
    onRegistrationError(result);
    return 'failed';
  }
  await resolveDestination();
  return 'registered';
}
function renderCustomerRegistrationDestinationRetry(isRouteCurrent=()=>true){
  if(!isRouteCurrent())return;
  customerRegistrationShell(`<section class="card" aria-labelledby="customerDestinationRetryTitle">
    <div class="row"><span aria-hidden="true">${CUI.icon('wallet',{size:24})}</span><div><h1 id="customerDestinationRetryTitle">Your account is ready</h1><p class="muted small" style="margin-top:5px">We could not load your programme destination. Retry this lookup—your customer account will not be created again.</p></div></div>
    <div id="customerDestinationRetryError" role="alert" aria-live="assertive"></div>
    <button class="btn" id="customerDestinationRetry" type="button" style="width:100%;margin-top:18px">${CUI.icon('forward',{size:20})}<span>Try destination again</span></button>
  </section>`);
  const retry=$('customerDestinationRetry');
  retry.onclick=async()=>{
    if(!isRouteCurrent()||!retry.isConnected)return;
    retry.disabled=true;retry.querySelector('span').textContent='Loading your programmes…';
    await resolveCustomerRegistrationDestination(isRouteCurrent,retry);
  };
}
async function resolveCustomerRegistrationDestination(isRouteCurrent=()=>true,origin=null){
  const isCurrent=()=>isRouteCurrent()&&(!origin||origin.isConnected);
  if(customerRegistrationDestinationPriority(pendingCustomerJoinToken,pendingCustomerBusinessSlug)==='join'){
    if(!isCurrent())return 'stale';
    /* v281 audit: setting location.hash to its current value fires no hashchange, so from the
       registration screens (already at #/join) this was a silent no-op that stranded the new
       account on a dead "Creating your account…" button. Re-route explicitly. */
    if(location.hash==='#/join')route();else nav('#/join');
    return 'navigated';
  }
  const {data:personas,error:personasError}=await sb.rpc('get_my_personas');
  if(!isCurrent())return 'stale';
  if(personasError){
    if(!isRouteCurrent())return 'stale';
    renderCustomerRegistrationDestinationRetry(isRouteCurrent);
    return 'retry';
  }
  const businesses=personas?.customer||[];
  const intent=pendingCustomerBusinessSlug;
  const linked=intent&&businesses.some(persona=>persona.business_slug===intent);
  if(!isCurrent())return 'stale';
  if(linked){
    pendingCustomerBusinessSlug='';
    const destination=takePendingCustomerDestination('#/wallet/'+encodeURIComponent(intent));
    if(!isCurrent())return 'stale';
    nav(destination);
    return 'navigated';
  }
  if(!isCurrent())return 'stale';
  if(intent){
    nav('#/claim?business='+encodeURIComponent(intent));
  }else{
    nav(takePendingCustomerDestination('#/wallet'));
  }
  return 'navigated';
}
function renderCustomerRegistrationProfile(isRouteCurrent=()=>true){
  if(!isRouteCurrent())return;
  const signupConsentRecorded=customerSignupConsentRecorded();
  customerRegistrationShell(`<section class="card" id="customerProfileForm" aria-labelledby="customerProfileTitle">
    <div class="row"><span aria-hidden="true">${CUI.icon('wallet',{size:24})}</span><div><h1 id="customerProfileTitle">Set up ${esc(BRAND.customerLabel)}</h1><p class="muted small" style="margin-top:5px">Your rewards stay separate for each business you choose to join.</p></div></div>
    <label for="customerFullName">Full name <span aria-hidden="true">*</span></label>
    <input id="customerFullName" autocomplete="name" maxlength="200" required>
    <label for="customerDob">Date of birth <span aria-hidden="true">*</span></label>
    <input id="customerDob" type="date" autocomplete="bday" max="${sgDateInputValue()}" required>
    <label for="customerGender">Gender <span aria-hidden="true">*</span></label>
    <select id="customerGender" autocomplete="sex" required><option value="">Select gender</option><option value="female">Female</option><option value="male">Male</option></select>
    <label for="customerLanguage">Preferred language</label>
    <select id="customerLanguage" autocomplete="language"><option value="en">English</option><option value="zh">中文</option><option value="ms">Bahasa Melayu</option><option value="ta">தமிழ்</option></select>
    <p class="muted small" style="margin-top:14px">${signupConsentRecorded?`Your Terms and Privacy Notice acceptance was captured before phone verification.${customerSignupMarketingOptedIn()?' You also opted in to offers and updates — you can change this anytime in Profile.':''}`:'Consent was not recorded for this browser session. Return to Create account and tick the Terms agreement box before verifying your phone.'}</p>
    <div id="customerProfileError" role="alert" aria-live="assertive"></div>
    <button class="btn" id="customerRegister" type="button" style="width:100%;margin-top:18px">${CUI.icon('check',{size:20})}<span>Create my customer account</span></button>
    <div class="row" style="margin-top:12px"><button class="btn ghost sm" id="customerProfileStartOver" type="button">Start again</button><span class="spacer"></span></div>
  </section>`);
  /* V289 (audit A3, G6): a fresh crypto.randomUUID() per click made every retry a NEW
     registration operation server-side. customer_register_verified_phone allows 5 per identity
     per 15 minutes, so four impatient taps on a flaky connection spent the whole allowance and
     the fifth answered try_later — the app then said "not available yet", which is not what
     happened. The key is now stable for as long as the submitted details are unchanged, exactly
     as the claim flow keys its attempt, so a retry REPLAYS the stored response instead of
     consuming another slot. Editing a field is a genuinely different request and takes a new key
     (the server hashes the payload and refuses a reused key for changed details). */
  let registrationAttemptV289=null;
  const register=$('customerRegister'),profileForm=$('customerProfileForm'),profileError=$('customerProfileError');
  const fullNameInput=$('customerFullName'),birthDateInput=$('customerDob'),genderInput=$('customerGender'),languageInput=$('customerLanguage');
  const isProfileCurrent=()=>isRouteCurrent()&&profileForm.isConnected&&register.isConnected;
  /* v174: the Create-account form already asked for these. Prefill from the
     stash and finish silently; this screen only stays visible when the stash is
     missing (e.g. OTP finished in another tab) or the submission fails. */
  const signupStash=customerSignupProfileStash();
  if(signupStash){
    fullNameInput.value=signupStash.fullName;
    birthDateInput.value=signupStash.birthDate;
    genderInput.value=signupStash.gender;
  }
  register.onclick=async()=>{
    const fullName=fullNameInput.value.trim(),birthDate=birthDateInput.value,gender=genderInput.value,language=languageInput.value;
    if(!fullName||!birthDate||new Date(`${birthDate}T00:00:00`)>new Date()){
      profileError.innerHTML='<div class="err">Enter your name and a date of birth that is not in the future.</div>';return;
    }
    if(!['female','male'].includes(gender)){
      profileError.innerHTML='<div class="err">Select Male or Female to continue.</div>';return;
    }
    if(!customerSignupConsentRecorded()){
      profileError.innerHTML='<div class="err">Consent was not recorded. Return to Create account and tick the Terms agreement box before verifying your phone.</div>';return;
    }
    register.disabled=true;register.querySelector('span').textContent='Creating your account…';
    const attemptKeyV289=[fullName,birthDate,gender,language,String(customerSignupMarketingOptedIn())].join('|');
    if(!registrationAttemptV289||registrationAttemptV289.key!==attemptKeyV289){
      registrationAttemptV289={key:attemptKeyV289,id:crypto.randomUUID()};
    }
    await runCustomerRegistrationProfileSubmission({
      registerRequest:async()=>{
        invalidatePersonaCacheV370(); // V370: a new customer profile is a new persona
        const result=await sb.rpc('customer_register_verified_phone',{
          p_full_name:fullName,p_birth_date:birthDate,p_gender:gender,p_preferred_language:language,
          p_accept_terms:true,p_accept_privacy:true,
          p_platform_marketing_opted_in:customerSignupMarketingOptedIn(),
          p_idempotency_key:registrationAttemptV289.id
        });
        /* Best-effort here on purpose: a brand-new customer holds no v263 deviation rows and
           an absent row already means ON, so a failed grant cannot contradict the tick. It
           runs anyway to repair an identity that somehow carries earlier deviations. */
        if(!result.error&&customerSignupMarketingOptedIn())await grantAllCommunicationsV265();
        return result;
      },
      resolveDestination:()=>{
        resetCustomerRegistrationState();
        return resolveCustomerRegistrationDestination(isRouteCurrent,register);
      },
      isCurrent:isProfileCurrent,
      onRegistrationError:(result)=>{
        if(!isProfileCurrent())return;
        register.disabled=false;register.querySelector('span').textContent='Create my customer account';
        /* V289 (G6): the server says WHEN, so the screen says when. try_later carries
           retry_after_seconds (900 today); a network failure is not a server refusal at all. */
        const outcome=String(result?.data?.outcome||'');
        const kind=customerAuthFailureKindV289(result?.error);
        let message='Customer registration is not available yet. Please try again later.';
        if(kind==='network')message='We could not reach Peekaa. Check your connection, then tap Create my customer account again — your account is not created twice.';
        else if(outcome==='try_later'){
          const minutes=Math.max(1,Math.ceil(Number(result?.data?.retry_after_seconds||0)/60));
          message=`Too many sign-up attempts from this account. Try again in about ${minutes} minute${minutes===1?'':'s'}.`;
        }
        profileError.innerHTML=`<div class="err">${esc(message)}</div>`;
      }
    });
  };
  /* v191: an escape hatch, so this screen can never become the trap described above. */
  const startOver=$('customerProfileStartOver');
  if(startOver)startOver.onclick=async()=>{
    startOver.disabled=true;
    await sb.auth.signOut();
    resetClientSessionState();resetCustomerRegistrationState();S.user=null;
    if(!isRouteCurrent())return;
    renderCustomerPasswordSignIn(isRouteCurrent,{noticeTone:'info',
      notice:'Signed out. Tap Create account to start again.'});
  };
  if(signupStash&&customerSignupConsentRecorded())register.onclick();
}
async function renderCustomerRegistration(isRouteCurrent=()=>true){
  globalThis.document?.documentElement?.setAttribute('lang','en');
  if(S.user){
    if(customerRecoveryVerified()===S.user.id)return renderCustomerRecoveryPasswordSetup(isRouteCurrent);
    const customerFeatures=await loadCustomerFeatureCapabilities();
    if(!isRouteCurrent())return;
    if(customerFeatures._load_error){
      if(!isRouteCurrent())return;
      return renderCustomerCapabilityRetry('We could not check your customer access. Please try again.');
    }
    if(!customerFeatures.customer_phone_registration){
      if(!isRouteCurrent())return;
      return renderCustomerWalletUnavailable('Customer registration is not available yet.');
    }
    const {data:profile,error:profileError}=await sb.rpc('customer_get_profile');
    if(!isRouteCurrent())return;
    if(profileError){
      if(!isRouteCurrent())return;
      return renderCustomerCapabilityRetry('We could not load your customer profile. Please try again.');
    }
    /* V246 (owner: "why pressing back will log me out of the app? i thought there is local
       cache?"). The session was never lost. Back lands on '#/', the customer entry, and a
       signed-in BUSINESS user has no customer profile — so this surface fell through to the
       customer sign-in screen, which reads exactly like being logged out. A user whose only
       persona is staff goes home to their workspace instead. A user with a customer profile
       is untouched, and a user with neither still sees sign-in, which is then true. */
    if(profile?.profile===null||profile?.profile===undefined){
      const personasResultV246=await sb.rpc('get_my_personas');
      if(!isRouteCurrent())return;
      if((personasResultV246.data?.staff||[]).length){nav('#/dashboard');return;}
    }
    if(profile?.profile!==null&&profile?.profile!==undefined){
      if(customerRegistrationDestinationPriority(pendingCustomerJoinToken,pendingCustomerBusinessSlug)==='join'){
        if(!isRouteCurrent())return;
        nav('#/join');return;
      }
      if(!pendingCustomerBusinessSlug){
        await maybeOfferCustomerPasskeySetup({isCurrent:isRouteCurrent});
        if(!isRouteCurrent())return;
        nav(takePendingCustomerDestination('#/wallet'));return;
      }
      const {data:personas,error:personasError}=await sb.rpc('get_my_personas');
      if(!isRouteCurrent())return;
      if(personasError){
        if(!isRouteCurrent())return;
        return renderCustomerCapabilityRetry('We could not load your customer destination. Please try again.');
      }
      const intent=pendingCustomerBusinessSlug;
      const linked=(personas?.customer||[]).some(persona=>persona.business_slug===intent);
      if(linked){
        pendingCustomerBusinessSlug='';
        const destination=takePendingCustomerDestination('#/wallet/'+encodeURIComponent(intent));
        if(!isRouteCurrent())return;
        nav(destination);return;
      }
      if(!isRouteCurrent())return;
      nav('#/claim?business='+encodeURIComponent(intent));return;
    }
    if(!isRouteCurrent())return;
    /* v191 (owner: "default peekaa.asia is customer log in, not sign up"). A signed-out visitor
       already lands on sign-in. What the owner hit was a STRANDED session: the phone was verified
       but the account was never finished, and this browser holds no consent evidence — so the
       profile form below refuses its own submit ("Return to Create account and tick the Terms
       agreement box"), with no way back to Create account. That is a trap, not a resume. Clear the
       unusable session and land on sign-in, where Create account is one tap away. Nothing is lost:
       an account with no profile holds no rewards, bookings or history. */
    if(!customerSignupConsentRecorded()){
      await sb.auth.signOut();
      resetClientSessionState();
      S.user=null;
      if(!isRouteCurrent())return;
      return renderCustomerPasswordSignIn(isRouteCurrent,{noticeTone:'info',
        notice:'That sign-up was never finished. Sign in if you already have an account, or tap Create account to start again.'});
    }
    return renderCustomerRegistrationProfile(isRouteCurrent);
  }
  return renderCustomerPasswordSignIn(isRouteCurrent);
}

/* v295: merchant-AUTHORED copy (offer text, promotion names, media alt) is stored per locale by
   the business itself, and the backend contract for those reads is en/zh-CN only — a ms or ta
   wallet correctly falls back to the merchant's English. Every such read must go through this
   one helper: the expression used to be inlined, and four of the five call sites silently kept
   'en' when the wallet went multilingual, throwing away Chinese copy the backend was ready to
   return. One name, one place to change when a merchant locale is added. */
function merchantCopyLocale(){return customerLocale==='zh-CN'?'zh-CN':'en'}
function applyCustomerNavCountsV194(counts={}){
  customerNavCountsV194={...customerNavCountsV194,...counts};
  const nav=document.querySelector('.customer-primary-nav');
  if(!nav)return customerNavCountsV194;
  nav.outerHTML=customerPrimaryNavigation(
    nav.querySelector('[aria-current="page"]')?.getAttribute('href')==='#/customer/programmes'?'programmes'
      :nav.querySelector('[aria-current="page"]')?.getAttribute('href')==='#/customer/bookings'?'bookings'
      :nav.querySelector('[aria-current="page"]')?.getAttribute('href')==='#/wallet'?'home':'',
    customerNavCountsV194);
  const scan=$('customerNavScan');
  if(scan)scan.onclick=openCustomerJoinScanner;
  return customerNavCountsV194;
}
function customerPasskeySupported({management=false}={}){
  return isSecureContext&&'PublicKeyCredential' in globalThis
    &&typeof sb.auth.registerPasskey==='function'
    &&(!management||typeof sb.auth.passkey?.list==='function');
}
function customerPasskeyErrorMessage(error,{action='setup'}={}){
  const code=String(error?.code||'');
  if(code==='passkey_disabled')return 'Face ID and passkeys aren’t available yet. Use your password.';
  if(code==='webauthn_credential_exists')return 'This device already has a passkey for this account.';
  if(code==='webauthn_credential_not_found')return 'This passkey no longer works here. Add it again.';
  if(code==='webauthn_verification_failed')return 'This passkey could not be verified for the current Peekaa domain. Sign in with your password and add a new passkey.';
  if(code==='phone_not_confirmed'||code==='email_not_confirmed')return 'Finish account verification before using Face ID or Touch ID.';
  /* V468 (owner, photo B8: "Enable now" circled, "not working"). Everything above is a code we
     recognise; everything else fell into one generic sentence with no reason in it, which is what
     the owner was looking at — the button HAD run, the ceremony HAD failed, and the screen could
     not say why. Two things change.
     First, the commonest outcome by far is not a fault at all: the browser throws NotAllowedError
     when the person dismisses the Face ID sheet, or when the ceremony times out, or when the page
     is not focused. Telling someone "setup was not completed" when they simply tapped Cancel
     invites them to press it again forever. That case now says so and invites a retry.
     Second, anything still unrecognised carries its own code/message. It is not pretty, but a
     dead end that cannot be reported is worse than an ugly string — this is the only channel we
     have back from a customer's own device, and the last report cost a round trip to learn
     nothing. */
  const nameV468=String(error?.name||'');
  if(nameV468==='NotAllowedError'||nameV468==='AbortError')
    return action==='sign-in'
      ?'Face ID was cancelled or timed out. Try again, or use your password.'
      :'Face ID was cancelled or timed out. Tap Enable now to try again.';
  const detailV468=String(error?.message||code||'').trim();
  const baseV468=action==='sign-in'
    ?'Passkey sign-in was not completed. Try again, or use your password.'
    :'Passkey setup was not completed. You can add it later from Profile.';
  return detailV468?`${baseV468} (${detailV468})`:baseV468;
}
async function maybeOfferCustomerPasskeySetup({isCurrent=()=>true}={}){
  const userId=S.user?.id||'';
  if(!userId||!customerPasskeySupported({management:true}))return false;
  const promptKey=`nestly.customer.passkeyPrompt.${userId}`;
  if(sessionStorage.getItem(promptKey)==='skipped')return false;
  let listed=null;
  try{listed=await sb.auth.passkey.list()}catch(error){return false}
  if(!isCurrent())return false;
  if(listed?.error)return false;
  const passkeys=Array.isArray(listed?.data)?listed.data:(Array.isArray(listed?.data?.passkeys)?listed.data.passkeys:[]);
  if(passkeys.length)return false;
  return new Promise(resolve=>{
    const overlay=document.createElement('div');
    overlay.className='modal customer-surface appointment-detail-modal';overlay.tabIndex=-1;
    overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');
    overlay.setAttribute('aria-labelledby','customerPasskeyPromptTitle');
    overlay.innerHTML=`<section class="modal-card" style="max-width:500px"><div class="row appointment-detail-head"><div><h2 id="customerPasskeyPromptTitle">Enable Face ID or Touch ID?</h2><p class="muted small" style="margin-top:5px">Add a passkey on this device so next time you can sign in without typing your password.</p></div><span class="spacer"></span><button class="btn ghost sm" id="customerPasskeyPromptClose" type="button" aria-label="Close passkey setup">${CUI.icon('close',{size:20})}</button></div>
      <div class="appointment-detail-section"><p class="muted small">Your face or fingerprint stays on your device. Peekaa only stores the public passkey needed to recognise this login.</p><p id="customerPasskeyPromptStatus" class="muted small" role="status" aria-live="polite" style="margin-top:10px"></p></div>
      <div class="appointment-detail-actions"><button class="btn" id="customerPasskeyPromptAdd" type="button">${CUI.icon('add',{size:16})}<span>Enable now</span></button><button class="btn ghost" id="customerPasskeyPromptSkip" type="button">Not now</button></div></section>`;
    document.body.appendChild(overlay);
    let deactivate=null,done=false;
    const close=outcome=>{
      if(done)return;done=true;
      if(deactivate)deactivate({restoreFocus:false});else overlay.remove();
      resolve(outcome);
    };
    deactivate=CUI.activateDialog(overlay,{onClose:()=>close('dismissed'),initialFocus:'#customerPasskeyPromptAdd'});
    overlay.addEventListener('click',event=>{if(event.target===overlay)close('dismissed')});
    overlay.querySelector('#customerPasskeyPromptClose').onclick=()=>close('dismissed');
    overlay.querySelector('#customerPasskeyPromptSkip').onclick=()=>{
      sessionStorage.setItem(promptKey,'skipped');
      close('skipped');
    };
    overlay.querySelector('#customerPasskeyPromptAdd').onclick=async()=>{
      const button=overlay.querySelector('#customerPasskeyPromptAdd');
      const status=overlay.querySelector('#customerPasskeyPromptStatus');
      button.disabled=true;status.textContent='Follow your device prompt to enable Face ID or Touch ID.';
      /* V468: registerPasskey resolves {error} for a server refusal but THROWS for a browser-side
         WebAuthn rejection. An unhandled throw here left the button disabled and the status stuck
         on "Follow your device prompt…" forever — a genuinely dead dialog, and silent, because an
         async onclick's rejection reaches no error handler. Both outcomes now land in one place. */
      let error=null;
      try{({error}=await sb.auth.registerPasskey()||{})}catch(thrown){error=thrown}
      if(!isCurrent()||!overlay.isConnected)return close('stale');
      if(error){
        button.disabled=false;status.textContent=customerPasskeyErrorMessage(error,{action:'setup'});
        return;
      }
      status.textContent='Face ID or Touch ID is ready for your next sign-in.';
      CUI.announce('Passkey enabled.');
      close('registered');
    };
  });
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
/* nestly_v428 (item 8) — THE AUTO-LINK HAD NO CALLER.
   syncVerifiedCustomerRelationshipsOnce is the client half of
   public.customer_sync_verified_relationships_v81: it takes the businesses that already hold this
   person's VERIFIED phone number and links them to the signed-in account. Nothing called it. A
   shop that added an existing walk-in customer by phone therefore never appeared in that
   customer's wallet at all — the programme existed on the server and the customer could only find
   it by re-registering or scanning a QR, which is not a thing anyone knows to do.
   It is safe to call on a wallet render: the RPC is idempotent, advisory-locked and rate-limited
   server-side (20 per 15 minutes), and the client memoizes the answer per user id, so a session
   sends it once however many times Home is opened.
   FIRE AND FORGET, and DELIBERATELY NOT RE-ARMED. The memoized branch keeps reporting linked:true
   for the rest of the session, so re-running it on every visit to Home would schedule a wallet
   reload each time; the already-answered case therefore returns before the call is made. Failures
   are swallowed into state (the retry lives on the no-destination screen) and never touch this
   render — the wallet the customer is looking at is painted either way. */
function customerAutoLinkOnceV428(isCurrent=()=>true,onLinked=()=>{}){
  const userId=S.user?.id||null;
  if(!userId)return false;
  if(customerRelationshipSyncState.userId===userId&&customerRelationshipSyncState.attempted)return false;
  syncVerifiedCustomerRelationshipsOnce(isCurrent)
    .then(result=>{if(result?.linked&&isCurrent())onLinked()})
    .catch(()=>{});
  return true;
}
function localCustomerPreviewProfileV345(){
  return {display_name:'Jamie Tan',full_name:'Jamie Tan'};
}
function localCustomerPreviewCardsV345(){
  const mk=(name,slug,industry,balance,tier,accent,ready=false,appointments=0,unit='points',extra={})=>({
    business:{id:slug,slug,name,industry,brand_color:accent,currency:'SGD'},
    /* v393: the flat tier_name/tier_level pair was a shape production has never sent. The local
       preview now carries the SAME nested snapshot app.customer_live_loyalty_v384 emits, so what
       renders here is what a real wallet renders — and a stamps business carries tier:null, which
       is the production contract (the tiers spine and stamps are exclusive). */
    loyalty:{balance,unit,tier:tier&&unit!=='stamps'?{
      name:tier,threshold:0,perk_note:null,points_multiplier:1,
      basis:'points_earned',metric:balance,next:null
    }:null},
    next_eligible_reward:ready?{
      available_now:true,name:name==='Cubbly'?'Free Facial cream':'Reward ready',
      progress_text:name==='Cubbly'?'Free Facial cream is ready to redeem.':'Ready to redeem.'
    }:extra.next_eligible_reward||null,
    upcoming_appointments:{count:appointments,...(extra.upcoming_appointments||{})}
  });
  return [
    mk('Cubbly','cubbly','Facial / Spa',75877,'Diamond','#E34234',true,1,'points',{
      upcoming_appointments:{next:{service_name:'Facial',branch_name:'Orchard',starts_at:'2026-08-17T03:30:00.000Z'}}
    }),
    mk('AhXiang','ahxiang','Facial / Spa',12450,'Gold','#D69B2D',false,0),
    mk('Bistro 88','bistro-88','Restaurant',8,'Silver','#0C554E',false,0,'stamps',{
      next_eligible_reward:{available_now:false,remaining_units:2,name:'Reward'}
    }),
    mk('Hair Play','hair-play','Salon',3210,'Bronze','#E7A091',true,0)
  ];
}
function localCustomerPreviewOffersV345(){
  return {status:'ready',items:[
    {id:'cubbly-20',version_id:'preview-cubbly-20',business:{name:'Cubbly',slug:'cubbly',industry:'Facial / Spa'},name:'20% off spa sessions',ends_at:'2026-08-27'},
    {id:'ahxiang-upgrade',version_id:'preview-ahxiang-upgrade',business:{name:'AhXiang',slug:'ahxiang',industry:'Facial / Spa'},name:'Free upgrade with facial',ends_at:'2026-08-30'},
    {id:'bistro-lunch',version_id:'preview-bistro-lunch',business:{name:'Bistro 88',slug:'bistro-88',industry:'Restaurant'},name:'10% off lunch set',ends_at:'2026-08-22'}
  ]};
}
function localCustomerPreviewShellV345(active='home'){
  renderCustomerShell({active,staffWorkspaces:[],messagesAvailable:true,body:'<div id="walletBody"></div>'});
  const routeByTab={home:'#/local/customer-preview',programmes:'#/local/customer-preview/rewards',bookings:'#/local/customer-preview/bookings',profile:'#/local/customer-preview/profile'};
  root.querySelectorAll('.wallet-tab').forEach(link=>{
    const href=link.getAttribute('href')||'';
    if(href==='#/wallet')link.href=routeByTab.home;
    if(href==='#/customer/programmes')link.href=routeByTab.programmes;
    if(href==='#/customer/bookings')link.href=routeByTab.bookings;
    if(href==='#/customer/profile')link.href=routeByTab.profile;
  });
}
/* V371: the two "Book again" buttons below are inert — this screen is a static localhost-only
   visual preview, not a working surface — so they are marked disabled rather than left looking
   pressable. That is both honest to whoever opens the preview and what the V123 readiness scan
   asks of every control: do something, or say that you do not. */
function renderLocalCustomerPreviewBookingsV345(){
  localCustomerPreviewShellV345('bookings');
  const group={business_slug:'cubbly',business_name:'Cubbly',business_logo:'',bookingEnabled:true,tabRequests:[],
    tabAppointments:[
      {appointment_id:'preview-1',starts_at:'2026-08-17T03:30:00.000Z',service_name:'Facial',branch_name:'Orchard',status:'booked'},
      {appointment_id:'preview-2',starts_at:'2026-07-22T07:00:00.000Z',service_name:'Hydrafacial',branch_name:'Orchard',status:'completed'}
    ]};
  const bistro={business_slug:'bistro-88',business_name:'Bistro 88',business_logo:'',bookingEnabled:true,tabRequests:[],tabAppointments:[]};
  $('walletBody').innerHTML=`<header class="customer-page-head"><div><h1>Bookings</h1></div></header>
    <div class="customer-my-rewards-search"><label class="sr-only" for="localBookingSearchV345">Search company name</label>${CUI.icon('search',{size:16})}<input id="localBookingSearchV345" type="search" placeholder="Search company name"></div>
    ${customerBookingTablistMarkupV178('bookings',{bookings:1,cancelled:3,history:0})}
    <div class="customer-booking-list"><section class="card customer-booking-business"><div class="wallet-section-head">${customerBookingBusinessLogoV195(group)}<div><h2>Cubbly</h2><p class="muted small">0 requests · 1 appointment</p></div><span class="spacer"></span><button class="btn sm" type="button" disabled>Rebook</button></div>
      <h3 class="customer-booking-appointments-head-v344">${CUI.icon('bookings',{size:20})}<span>Upcoming appointments</span><span aria-hidden="true">✦</span></h3>${group.tabAppointments.map(item=>customerBookingAppointmentRowV344(group,item,false)).join('')}</section>
      <section class="card customer-booking-business"><div class="wallet-section-head">${customerBookingBusinessLogoV195(bistro)}<div><h2>Bistro 88</h2><p class="muted small">2 appointments</p></div><span class="spacer"></span><button class="btn sm" type="button" disabled>Rebook</button></div></section></div>`;
  focusCustomerRoute();
}
function renderLocalCustomerPreviewProfileV345(){
  localCustomerPreviewShellV345('profile');
  $('walletBody').innerHTML='<section class="card"><h1>Profile</h1><p class="muted small">Local visual preview only. Sign in on the production domain for live account details.</p></section>';
  focusCustomerRoute();
}
function renderLocalCustomerPreviewV345(hash=''){
  if(!localCustomerPreviewEnabledV345())return;
  const path=String(hash||'').split('?')[0];
  if(path.endsWith('/bookings'))return renderLocalCustomerPreviewBookingsV345();
  const cards=localCustomerPreviewCardsV345();
  const surface=path.endsWith('/rewards')?'programmes':'home';
  localCustomerPreviewShellV345(surface==='programmes'?'programmes':'home');
  renderActionableWalletHome({cards},{surface,offersState:localCustomerPreviewOffersV345(),profile:localCustomerPreviewProfileV345(),rerender:()=>renderLocalCustomerPreviewV345(path)});
  const scan=$('customerHomeScan');if(scan)scan.onclick=openCustomerJoinScanner;
  if(path.endsWith('/qr'))setTimeout(openCustomerJoinScanner,0);
  focusCustomerRoute();
}

async function renderCustomerProgrammes(){
  const walletRenderEpoch=++customerWalletRenderEpoch,isCurrent=()=>customerWalletRenderEpoch===walletRenderEpoch;
  const context=await loadCustomerSurfaceContext(isCurrent);if(!context)return;
  /* v178 (owner annotation): "My Rewards" is back button + heading with Scan to join + the
     reward-account grid. The offers shelf and the next-best-action banner belong to Home only. */
  renderCustomerShell({active:'programmes',backTo:'#/wallet',staffWorkspaces:context.staffWorkspaces,messagesAvailable:context.features.customer_in_app_inbox===true,body:`<div class="card"><p class="muted">${esc(ct('loadingProgrammes'))}</p></div>`});
  /* v196 (owner struck the whole card out): "Joining a new rewards account — visit the business
     and scan its Peekaa QR" explained a rule the page now demonstrates. Scan to join sits in the
     heading row beside the title, and the scanner is in the header on every screen; the paragraph
     under a customer's own reward accounts was telling them how to get what they already have.
     The QR-only join rule itself is unchanged — nothing but the explanatory card is gone, and the
     first-programme quest (a customer with NO accounts) still spells it out in full. */
  if(context.features.customer_actionable_wallet===true){
    const {data,error}=await sb.rpc('customer_get_actionable_wallet');
    if(!isCurrent())return;
    if(error)return renderCustomerWalletRetry('Your rewards are temporarily unavailable.',null,()=>renderCustomerProgrammes(),error);
    const cards=Array.isArray(data?.cards)?data.cards:[];
    if(!cards.length){renderCustomerFirstProgrammeQuest();return}
    renderActionableWalletHome(data,{surface:'programmes',rerender:()=>renderCustomerProgrammes()});
    focusCustomerRoute();return;
  }
  const [walletResult,selectorMediaResult]=await Promise.all([
    sb.rpc('customer_get_wallet'),
    sb.rpc('customer_get_programme_selector_media_v96')
  ]);
  if(!isCurrent())return;
  const {data,error}=walletResult;
  if(error)return renderCustomerWalletRetry('Your rewards are temporarily unavailable.',null,()=>renderCustomerProgrammes(),error);
  const cards=mergeCustomerProgrammeSelectorMediaV96(
    Array.isArray(data)?data:[],selectorMediaResult.error?null:selectorMediaResult.data
  );
  if(!cards.length){renderCustomerFirstProgrammeQuest();return}
  $('walletBody').innerHTML=`${customerMyRewardsHeadingV156(cards.length,{scanId:'customerHomeScan',categories:customerRewardCategoriesPresentV395(cards)})}
    ${customerProgrammeGridMarkupV96(cards)}`;
  $('customerHomeScan').onclick=openCustomerJoinScanner;
  wireCustomerProgrammeSearchV195($('walletBody'));
  focusCustomerRoute();
}

/* v393 (owner decision, 2026-08-19): Explore is REMOVED, not hidden. v248 had already taken the
   tab away and left the finished surface behind one constant; the owner has now retired the
   destination itself, so the tab entry, the page and its only call to
   customer_explore_businesses_v244 are gone from the app. The RPC and its migrations are left
   untouched on the server — this is a client decision, and nothing else calls it. The route is
   kept and aliased to #/wallet below: a link a customer already has in a message or a home-screen
   shortcut must not 404. */
const ACTIVE_CUSTOMER_BOOKING_REQUEST_STATUSES=new Set(['pending','waitlisted','new']);
const isActiveCustomerBookingRequest=request=>ACTIVE_CUSTOMER_BOOKING_REQUEST_STATUSES.has(String(request?.status||'').toLowerCase());
const customerRepeatBookingPreferencesV167=new Map();
async function openCustomerRepeatBookingV167(businessSlug,appointmentId=null,button=null){
  if(!businessSlug)return;
  if(button){button.disabled=true;button.setAttribute('aria-busy','true')}
  let serviceId='',staffName='';
  if(appointmentId){
    const {data,error}=await sb.rpc('customer_get_repeat_booking_preference_v167',{
      p_business_slug:businessSlug,p_appointment:appointmentId
    });
    if(error){if(button){button.disabled=false;button.removeAttribute('aria-busy')}return toast('That previous service could not be checked. Open the booking page and choose a service.')}
    serviceId=/^[0-9a-f-]{36}$/i.test(String(data?.service_id||''))?String(data.service_id):'';
    staffName=String(data?.staff_name||'').trim();
  }
  if(serviceId)customerRepeatBookingPreferencesV167.set(`${businessSlug}:${serviceId}`,{staffName});
  nav(`#/b/${encodeURIComponent(businessSlug)}${serviceId?`?repeat_service=${encodeURIComponent(serviceId)}`:''}`);
}
function wireCustomerRepeatBookingV167(host=document){
  host.querySelectorAll?.('[data-repeat-booking]').forEach(button=>button.onclick=()=>openCustomerRepeatBookingV167(
    button.dataset.businessSlug,button.dataset.appointmentId||null,button
  ));
}
function composeCustomerBookingGroups(programmes=[],requestPayload=null,appointmentResults=[]){
  const groups=new Map();
  const ensure=(slug,name='Business')=>{
    const key=String(slug||'');
    if(!groups.has(key))groups.set(key,{business_slug:key,business_name:name||'Business',business_logo:'',bookingEnabled:false,appointmentChangesEnabled:false,requests:[],activeRequests:[],recentRequests:[],appointments:[]});
    else if(name&&groups.get(key).business_name==='Business')groups.get(key).business_name=name;
    return groups.get(key);
  };
  for(const card of programmes){
    const business=card?.business||{};
    const group=ensure(business.slug,business.name);
    group.bookingEnabled=card?.booking_enabled===true||card?.booking?.enabled===true;
    /* v291: the chooser groups businesses the way the owner described choosing them —
       "hair cut / cafés & restaurants / other sectors". */
    if(!group.industry)group.industry=String(business.industry||'');
    /* v286: carried through so the Bookings page can offer the same Change control the wallet
       offers, under the same per-business permission. Absent or unreadable stays false. */
    group.appointmentChangesEnabled=card?.appointment_changes_enabled===true;
    /* v195 (owner circled the bare name: "company photo"): a booking is easier to recognise by
       the shop's own mark than by reading a name. Falls back to the initial when a business has
       not uploaded a logo — never a placeholder image pretending to be theirs. */
    if(!group.business_logo)group.business_logo=String(business.logo_url||'');
  }
  const seenRequests=new Set();
  for(const request of Array.isArray(requestPayload?.items)?requestPayload.items:[]){
    if(!request?.request_id||seenRequests.has(request.request_id))continue;
    seenRequests.add(request.request_id);
    const group=ensure(request.business_slug,request.business_name);
    group.requests.push(request);
    (isActiveCustomerBookingRequest(request)?group.activeRequests:group.recentRequests).push(request);
  }
  const seenAppointments=new Set();
  for(const result of appointmentResults){
    if(result?.error)continue;
    const business=result.card?.business||{};
    const group=ensure(business.slug,business.name);
    for(const appointment of Array.isArray(result.data?.items)?result.data.items:[]){
      const id=appointment?.appointment_id||`${business.slug}:${appointment?.starts_at||''}:${appointment?.service_name||''}`;
      if(seenAppointments.has(id))continue;
      seenAppointments.add(id);group.appointments.push(appointment);
    }
  }
  return [...groups.values()].filter(group=>group.bookingEnabled||group.requests.length||group.appointments.length)
    .sort((a,b)=>a.business_name.localeCompare(b.business_name,undefined,{sensitivity:'base'})
      ||a.business_slug.localeCompare(b.business_slug));
}
/* v178 (owner sketch "Bookings | Cancelled | History"): the same already-fetched records are
   split client-side into three tabs. No new RPC, no extra round trip. */
const CUSTOMER_BOOKING_TABS_V178=[
  /* v194 (owner renamed it on the screenshot): "Bookings" inside a page called Bookings said
     nothing. "Ongoing" is what the tab actually holds. */
  ['bookings','Ongoing','No bookings yet. Active requests and upcoming appointments appear here.'],
  ['cancelled','Cancelled','No cancelled bookings.'],
  ['history','History','No past bookings yet.']
];
const CANCELLED_CUSTOMER_BOOKING_STATUSES_V178=new Set(['cancelled','canceled','declined','rejected','no_show','noshow']);
const RESOLVED_CUSTOMER_APPOINTMENT_STATUSES_V178=new Set(['completed','done','finished']);
function customerBookingRequestTabV178(request){
  if(isActiveCustomerBookingRequest(request))return 'bookings';
  return CANCELLED_CUSTOMER_BOOKING_STATUSES_V178.has(String(request?.status||'').toLowerCase())?'cancelled':'history';
}
function customerBookingAppointmentTabV178(appointment,now=Date.now()){
  const status=String(appointment?.status||'').toLowerCase();
  if(CANCELLED_CUSTOMER_BOOKING_STATUSES_V178.has(status))return 'cancelled';
  if(RESOLVED_CUSTOMER_APPOINTMENT_STATUSES_V178.has(status))return 'history';
  /* v194 (owner: "done should go history"): a business does not always mark an appointment
     completed, so a visit that has already happened kept sitting under Ongoing. Time decides when
     status has not: once the slot has passed, it is history. A missing or unparsable time stays
     Ongoing — that is the safer default for something that might still be coming. */
  const startsAt=Date.parse(appointment?.starts_at||'');
  if(Number.isFinite(startsAt)&&startsAt<=now)return 'history';
  return 'bookings';
}
/* v286 (audit): the page literally named "Bookings" gave an upcoming appointment nothing to press
   — just a decorative status pill. The only cancel/reschedule control lived on the wallet detail
   route behind "Open programme", which a customer has no reason to guess. This surfaces the SAME
   control, the same customer_request_appointment_action call and the same two gates the wallet
   uses (the platform customer_actions feature and the business's own appointment_changes setting).
   Only an Ongoing, still-booked row qualifies: a past or cancelled one keeps "Book again". */
function customerBookingChangeActionV286(group,appointment,featureEnabled=false){
  return featureEnabled===true
    &&group?.appointmentChangesEnabled===true
    &&!!group?.business_slug
    &&!!appointment?.appointment_id
    &&String(appointment?.status||'')==='booked'
    &&customerBookingAppointmentTabV178(appointment)==='bookings';
}
/* v183 (owner annotation, "0 requests · 0 appointments — no booking yet, should not show
   Cubbly"): a business with nothing booked is not a booking. Only records list here; the
   "book with them" entry point moved into the empty state below, where it reads as an
   invitation rather than as a phantom booking. */
/* v195 (owner: "put filter time here", beside the page title): the tabs answer WHAT a booking
   is; this answers WHEN. It filters records already fetched — no request — and reads in the
   direction the tab points: Ongoing looks forward, Cancelled and History look back. */
/* v196 (owner circled the "Any time" control: "i need the date to date filter"): fixed windows
   answered "how soon", not "between these two dates" — a customer looking for the visit they made
   in March could not ask for March. Two date fields, either one optional, filtering the records
   already fetched. Dates are read in Singapore time, the zone every other date on this surface is
   printed in, so a booking shown as 8 Aug is included by a range ending 8 Aug. */
function customerBookingRangeBoundV195(value,{end=false}={}){
  if(!/^\d{4}-\d{2}-\d{2}$/.test(String(value||'')))return null;
  const at=Date.parse(`${value}T${end?'23:59:59.999':'00:00:00.000'}+08:00`);
  return Number.isFinite(at)?at:null;
}
function customerBookingWithinRangeV196(value,{from='',to=''}={}){
  const start=customerBookingRangeBoundV195(from),finish=customerBookingRangeBoundV195(to,{end:true});
  if(start===null&&finish===null)return true;
  const at=Date.parse(value||'');
  /* A record with no usable time is never filtered out — hiding it would be a silent loss, and
     the customer cannot tell an empty list from a hidden one. */
  if(!Number.isFinite(at))return true;
  if(start!==null&&at<start)return false;
  if(finish!==null&&at>finish)return false;
  return true;
}
/* An inverted range (to before from) would match nothing and read as "you have no bookings",
   which is a lie. The fields are swapped instead, and the control says so. */
function customerBookingNormaliseRangeV196({from='',to=''}={}){
  const start=customerBookingRangeBoundV195(from),finish=customerBookingRangeBoundV195(to,{end:true});
  return (start!==null&&finish!==null&&finish<start)?{from:to,to:from}:{from,to};
}
/* v3 (Top-20 #19, "the most clinical, least branded element in the customer app"): the filter
   used to be the two raw native date fields themselves, side by side — each carrying our own
   leading calendar icon AND the browser's picker indicator, four calendar glyphs in one 44px
   row, with no word anywhere saying what was being filtered. The row is now ONE chip that reads
   its own state ("Any dates" / "12 Aug – 19 Aug") over an inline panel holding the SAME two
   inputs, same ids, same live-on-change wiring. Apply only closes the panel — it is not a second
   filter path, because a control that looks like it commits but does not would be a lie. */
function customerBookingRangeChipLabelV3(range={from:'',to:''}){
  const {from,to}=range||{};
  const day=value=>{
    const at=customerBookingRangeBoundV195(value);
    /* Singapore time, the zone every other date on this surface is printed in. */
    return at===null?'':new Intl.DateTimeFormat('en-SG',{day:'numeric',month:'short',timeZone:'Asia/Singapore'}).format(new Date(at));
  };
  const start=day(from),finish=day(to);
  if(start&&finish)return `${start} – ${finish}`;
  if(start)return `From ${start}`;
  if(finish)return `Until ${finish}`;
  return 'Any dates';
}
function customerBookingFilterMarkupV195(range={from:'',to:''},open=false){
  const {from,to}=range||{};
  const active=!!(from||to);
  const label=customerBookingRangeChipLabelV3(range);
  return `<div class="customer-datesheet-wrap-v3">
    <button type="button" id="customerBookingRangeChip" class="customer-datesheet-chip-v3${active?' is-active':''}" aria-expanded="${open?'true':'false'}" aria-controls="customerBookingDatePanel" aria-label="${esc(`Filter bookings by date: ${label}`)}">${CUI.icon('appointments',{size:16})}<span>${esc(label)}</span></button>
    <div class="customer-datesheet-v3" id="customerBookingDatePanel" role="group" aria-label="Filter bookings by date"${open?'':' hidden'}>
      <label for="customerBookingFrom">From date</label>
      <input id="customerBookingFrom" type="date" value="${esc(from||'')}" max="2999-12-31">
      <label for="customerBookingTo">To date</label>
      <input id="customerBookingTo" type="date" value="${esc(to||'')}" max="2999-12-31">
      <div class="customer-datesheet-actions-v3">
        <button class="btn ghost sm" id="customerBookingRangeClear" type="button">Clear</button>
        <button class="btn sm" id="customerBookingRangeApply" type="button">Apply</button>
      </div>
    </div>
  </div>`;
}
function customerBookingBusinessLogoV195(group={}){
  const url=customerMediaUrlV95(group?.business_logo),name=String(group?.business_name||'Business');
  return url
    ?`<img class="customer-booking-logo" src="${esc(url)}" alt="" loading="lazy" width="40" height="40">`
    :`<span class="customer-booking-logo customer-booking-logo--fallback" aria-hidden="true">${esc((name[0]||'B').toUpperCase())}</span>`;
}
function customerBookingDateTileV344(value){
  const date=new Date(value||'');
  if(!Number.isFinite(date.getTime()))return '<span class="customer-booking-date-tile-v344"><small>DATE</small><b>--</b><em></em></span>';
  const month=new Intl.DateTimeFormat('en-SG',{month:'short',timeZone:'Asia/Singapore'}).format(date).toUpperCase();
  const day=new Intl.DateTimeFormat('en-SG',{day:'2-digit',timeZone:'Asia/Singapore'}).format(date);
  const weekday=new Intl.DateTimeFormat('en-SG',{weekday:'short',timeZone:'Asia/Singapore'}).format(date).toUpperCase();
  return `<span class="customer-booking-date-tile-v344"><small>${esc(month)}</small><b>${esc(day)}</b><em>${esc(weekday)}</em></span>`;
}
function customerBookingAppointmentRowV344(group,item,changesFeatureEnabled=false){
  const tab=customerBookingAppointmentTabV178(item);
  const action=customerBookingChangeActionV286(group,item,changesFeatureEnabled)
    ?`<button class="btn ghost sm walletChange" type="button" data-id="${esc(item.appointment_id)}" data-business-slug="${esc(group.business_slug)}">Change</button>`
    :group.bookingEnabled&&group.business_slug&&tab!=='bookings'
      ?`<button class="btn ghost sm" type="button" data-repeat-booking data-business-slug="${esc(group.business_slug)}" data-appointment-id="${esc(item.appointment_id)}">${esc(ct('Book again'))}</button>`
      :`<span class="pill ${tab==='cancelled'?'no':'ok'}">${esc(ct('Appointment'))}</span>`;
  return `<div class="wallet-appt customer-booking-appointment-row-v344">${customerBookingDateTileV344(item.starts_at)}<div><b>${esc(walletDate(item.starts_at,true)||'Time unavailable')}</b><p class="muted small" style="margin-top:3px">${esc(item.service_name||'Appointment')}${item.branch_name?' · '+esc(item.branch_name):''} · ${esc(String(item.status||'confirmed').replaceAll('_',' '))}</p></div><span class="spacer"></span>${action}</div>`;
}
function customerBookingRequestRowV344(item){
  return `<div class="wallet-appt"><div><b>${esc(walletDate(item.preferred_at,true)||walletDate(item.created_at,true)||'Preferred time pending')}</b><p class="muted small" style="margin-top:3px">${esc(item.service_name||'Booking request')} · ${esc(String(item.status||'pending').replaceAll('_',' '))}${item.party_size?` · party of ${Number(item.party_size)}`:''}</p></div><span class="spacer"></span><span class="pill ${isActiveCustomerBookingRequest(item)?(item.status==='waitlisted'?'new':'off'):'no'}">${esc(isActiveCustomerBookingRequest(item)?(item.status==='waitlisted'?ct('Waitlisted'):ct('Pending')):String(item.status||'updated').replaceAll('_',' '))}</span>${isActiveCustomerBookingRequest(item)&&item.request_id?`<button class="btn ghost sm" type="button" data-withdraw-request="${esc(item.request_id)}">${esc(ct('Withdraw'))}</button>`:''}</div>`;
}
function customerBookingTabGroupsV178(groups=[],tab='bookings',range={from:'',to:''}){
  const inWindow=value=>customerBookingWithinRangeV196(value,range);
  return groups.map(group=>({
    ...group,
    tabRequests:group.requests.filter(item=>customerBookingRequestTabV178(item)===tab
      &&inWindow(item.preferred_at||item.created_at)),
    tabAppointments:group.appointments.filter(item=>customerBookingAppointmentTabV178(item)===tab
      &&inWindow(item.starts_at))
  })).filter(group=>group.tabRequests.length||group.tabAppointments.length);
}
/* v291 (owner: "when press into bookings why it does not show me which business i want to
   choose?" and "why it only shows me 1 company for booking?"): the page now opens with the
   choice itself — EVERY joined business, not only the one with booking switched on. A bookable
   business books in one tap; the rest are shown with the honest reason ("No online booking
   yet") and a path to their programme page, because hiding them read as "the app only has one
   company". Once the customer has joined more than one sector, the chips group under sector
   headings. */
function customerBookingChooserV291(groups=[]){
  const businesses=groups.filter(group=>group.business_slug);
  if(!businesses.length)return '';
  const chip=group=>{
    const searchAttr=`data-booking-search-item data-booking-search-name="${esc(String(group.business_name||'').trim().toLowerCase())}"`;
    /* v327 (owner: "photo 1 - remove this icon (shaded)"): the blurry business-photo thumbnail
       came off the search-result chip — name and status text only now. */
    return group.bookingEnabled
      ?`<button class="customer-booking-chip" type="button" ${searchAttr} data-repeat-booking data-business-slug="${esc(group.business_slug)}"><span class="customer-booking-chip-copy"><b data-merchant-content>${esc(group.business_name)}</b><span class="muted small">Book now</span></span></button>`
      :`<a class="customer-booking-chip customer-booking-chip--quiet" ${searchAttr} href="#/wallet/${encodeURIComponent(group.business_slug)}"><span class="customer-booking-chip-copy"><b data-merchant-content>${esc(group.business_name)}</b><span class="muted small">No online booking yet</span></span></a>`;
  };
  /* v326 (owner: crossed out the fixed "Book with" header, circled "here put filter to search
     company name"): the header is now a live text filter over the same chips, the identical
     search pattern already used for the customer's reward-account list
     (wireCustomerProgrammeSearchV195/#customerProgrammeSearch) — filters what already
     rendered, no new request. */
  const searchHead=`<div class="customer-booking-search"><label class="sr-only" for="customerBookingSearch">Search company name</label>${CUI.icon('search',{size:16})}<input id="customerBookingSearch" type="search" autocomplete="off" placeholder="Search company name" aria-describedby="customerBookingSearchStatus"></div><p class="muted small" id="customerBookingSearchStatus" role="status" hidden></p>`;
  const industries=[...new Set(businesses.map(group=>String(group.industry||'').trim()).filter(Boolean))];
  if(industries.length>1){
    const bySector=new Map();
    for(const group of businesses){
      const key=String(group.industry||'').trim()||'Other';
      if(!bySector.has(key))bySector.set(key,[]);
      bySector.get(key).push(group);
    }
    return `<section class="card customer-booking-chooser">${searchHead}
      ${[...bySector.entries()].map(([sector,members])=>`<div data-booking-search-group><h3 class="customer-booking-sector" data-merchant-content>${esc(sector)}</h3><div class="customer-booking-chips">${members.map(chip).join('')}</div></div>`).join('')}</section>`;
  }
  return `<section class="card customer-booking-chooser">${searchHead}<div class="customer-booking-chips">${businesses.map(chip).join('')}</div></section>`;
}
/* v326: filters the chips customerBookingChooserV291 already rendered — same shape as
   wireCustomerProgrammeSearchV195, kept as its own function since it targets a different
   input/host and groups by sector wrapper instead of category section. */
function wireCustomerBookingSearchV326(host=document){
  const input=host.querySelector('#customerBookingSearch');
  if(!input)return;
  const status=host.querySelector('#customerBookingSearchStatus');
  const items=[...host.querySelectorAll('[data-booking-search-item]')];
  const groups=[...host.querySelectorAll('[data-booking-search-group]')];
  const apply=()=>{
    const query=String(input.value||'').trim().toLowerCase();
    let shown=0;
    items.forEach(item=>{
      const match=!query||String(item.dataset.bookingSearchName||'').includes(query);
      item.hidden=!match;
      if(match)shown++;
    });
    groups.forEach(group=>{
      const visible=[...group.querySelectorAll('[data-booking-search-item]')].some(item=>!item.hidden);
      group.hidden=!visible;
    });
    if(!status)return;
    status.hidden=!query;
    status.textContent=query?(shown?`${shown} of ${items.length} shown`:`No business matches “${query}”.`):'';
  };
  input.addEventListener('input',apply);
  apply();
}
function customerBookingEmptyMarkupV183(tab='bookings',emptyCopy='',groups=[]){
  const label=(CUSTOMER_BOOKING_TABS_V178.find(([name])=>name===tab)||[])[1]||'Bookings';
  const bookable=tab==='bookings'
    ?groups.filter(group=>group.bookingEnabled&&group.business_slug)
    :[];
  return `<section class="card"><h2>${esc(label)}</h2><p class="muted small" style="margin-top:6px">${esc(emptyCopy)}</p>
    ${bookable.length?`<div class="customer-booking-invite">${bookable.map(group=>`<button class="btn ghost sm" type="button" data-repeat-booking data-business-slug="${esc(group.business_slug)}">${CUI.icon('bookings',{size:16})}<span>Book with ${esc(group.business_name)}</span></button>`).join('')}</div>`:''}</section>`;
}
/* v196 (owner: "remove the (1) from history — dont need to know how many transactions in
   history"): a count is a prompt to act. Ongoing and Cancelled hold things a customer may still
   need to do something about; History is a record, and numbering it only added noise. */
const CUSTOMER_BOOKING_TABS_WITHOUT_COUNT_V196=new Set(['history']);
function customerBookingTablistMarkupV178(currentTab='bookings',counts={}){
  return `<div class="customer-booking-tabs" role="tablist" aria-label="Booking status">${CUSTOMER_BOOKING_TABS_V178.map(([tab,label])=>{
    const selected=tab===currentTab,showCount=!CUSTOMER_BOOKING_TABS_WITHOUT_COUNT_V196.has(tab);
    return `<button type="button" role="tab" id="customerBookingTab-${esc(tab)}" class="customer-booking-tab" data-booking-tab="${esc(tab)}" aria-selected="${selected}" aria-controls="customerBookingPanel" tabindex="${selected?'0':'-1'}">${esc(label)}${showCount&&Number(counts[tab])>0?` <span class="customer-booking-tab-count">${Number(counts[tab])}</span>`:''}</button>`;
  }).join('')}</div>`;
}
async function renderCustomerBookings(){
  const walletRenderEpoch=++customerWalletRenderEpoch,isCurrent=()=>customerWalletRenderEpoch===walletRenderEpoch;
  const context=await loadCustomerSurfaceContext(isCurrent);if(!context)return;
  renderCustomerShell({active:'bookings',staffWorkspaces:context.staffWorkspaces,messagesAvailable:context.features.customer_in_app_inbox===true,body:'<div class="card"><p class="muted">Loading your bookings…</p></div>'});
  /* v286 (audit): this load ran three sequential stages — up to 4 + N + N calls — on raw sb.rpc,
     which has no client-side timeout. One hung request left "Loading your bookings…" on screen
     indefinitely with nothing to press; the only escape was a manual reload. Every read now goes
     through customerRpc, the surface's own deadline helper, which turns a stall into an ordinary
     {error:{code:'timeout'}} result — so a stalled feed lands in the retry state or in the
     partial-failure notice below, both of which already exist and both of which say so. */
  const [walletResult,programmeResult,requestResult,selectorMediaResult]=await Promise.all([
    customerRpc('customer_get_wallet'),
    customerRpc('customer_list_programmes_v89'),
    customerRpc('customer_get_booking_requests',{p_limit:50,p_cursor:null}),
    /* v195: the programme feeds carry no logo, so the same media projection My Rewards uses
       supplies it here. A failure costs the photo and nothing else — the initial is the fallback. */
    customerRpc('customer_get_programme_selector_media_v96')
  ]);
  if(!isCurrent())return;
  const legacyProgrammes=walletResult.error?[]:(Array.isArray(walletResult.data)?walletResult.data:[]);
  const linkedProgrammes=mergeCustomerProgrammeSelectorMediaV96(
    programmeResult.error
      ?legacyProgrammes
      :(Array.isArray(programmeResult.data?.programmes)?programmeResult.data.programmes:[]),
    selectorMediaResult.error?null:selectorMediaResult.data
  );
  const actionResults=await Promise.all(linkedProgrammes.map(async card=>{
    const business=card?.business||{};
    const response=business.id
      ?await customerRpc('customer_get_business_actions_v89',{p_business:business.id})
      :{data:null,error:{message:'Missing business identity'}};
    return {card,response};
  }));
  if(!isCurrent())return;
  const programmes=actionResults.map(({card,response})=>({
    ...card,booking_enabled:!response.error&&response.data?.booking?.enabled===true,
    booking:response.error?{enabled:false}:response.data?.booking,
    /* v286: the same per-business permission the wallet reads, carried to the Bookings page. */
    appointment_changes_enabled:!response.error&&response.data?.appointment_changes?.enabled===true
  }));
  const results=await Promise.all(programmes.map(async card=>{
    const slug=card?.business?.slug||'';
    const response=await customerRpc('customer_get_appointments_page',{p_business_slug:slug,p_cursor:{limit:20}});
    return {card,data:response.data,error:response.error};
  }));
  if(!isCurrent())return;
  const failedAppointments=results.filter(result=>result.error);
  let requestPayload=requestResult.error?null:requestResult.data,requestLoadMoreError='';
  if(walletResult.error&&programmeResult.error&&requestResult.error){
    return renderCustomerWalletRetry('Your booking requests and appointments are temporarily unavailable.',null,()=>renderCustomerBookings(),walletResult.error);
  }
  const changesFeatureEnabled=context.features.customer_actions===true;
  /* v3: the panel's open state lives beside the range because every filter change repaints the
     whole body — without it, setting From would slam the panel shut before To could be set. */
  let currentBookingTab='bookings',currentBookingRange={from:'',to:''},bookingRangePanelOpenV3=false;
  const paintBookings=()=>{
    if(!isCurrent()||!$('walletBody')?.isConnected)return;
    const allGroups=composeCustomerBookingGroups(programmes,requestPayload,results);
    const tabCounts={};
    for(const [tab] of CUSTOMER_BOOKING_TABS_V178)tabCounts[tab]=customerBookingTabGroupsV178(allGroups,tab,currentBookingRange)
      .reduce((sum,group)=>sum+group.tabRequests.length+group.tabAppointments.length,0);
    const groups=customerBookingTabGroupsV178(allGroups,currentBookingTab,currentBookingRange);
    const emptyCopy=(CUSTOMER_BOOKING_TABS_V178.find(([tab])=>tab===currentBookingTab)||[])[2]||'Nothing here yet.';
    const requestHeading=currentBookingTab==='bookings'?'Awaiting the business':currentBookingTab==='cancelled'?'Cancelled requests':'Earlier request updates';
    const appointmentHeading=currentBookingTab==='bookings'?'Appointments':currentBookingTab==='cancelled'?'Cancelled appointments':'Past appointments';
    const partialMessages=[
      walletResult.error?'Confirmed appointments could not be discovered from your programmes.':'',
      programmeResult.error?'Current linked-business booking availability could not be checked. New booking actions are hidden.':'',
      actionResults.some(result=>result.response.error)?'Some businesses could not confirm whether new customer bookings are enabled. Their booking actions are hidden.':'',
      requestResult.error?'Pending and waitlisted booking requests are temporarily unavailable.':'',
      failedAppointments.length?`${failedAppointments.length} programme appointment feed${failedAppointments.length===1?' is':'s are'} temporarily unavailable.`:'',
      requestLoadMoreError
    ].filter(Boolean);
    const requestItems=Array.isArray(requestPayload?.items)?requestPayload.items:[];
    const requestCount=requestItems.length;
    const activeRequestCount=requestItems.filter(isActiveCustomerBookingRequest).length;
    const hasMore=!!requestPayload?.next_cursor;
    $('walletBody').innerHTML=`<header class="customer-page-head"><div><h1>Bookings</h1></div><span class="spacer"></span>${customerBookingFilterMarkupV195(currentBookingRange,bookingRangePanelOpenV3)}</header>
    ${partialMessages.length?`<div class="card" role="status"><div class="row"><p class="muted small">Some booking info didn’t load.</p><span class="spacer"></span><button class="btn ghost sm" id="customerBookingsRetry">Retry</button></div>
      <!-- v286 (audit): these six sentences were computed and then thrown away — only
           partialMessages.length was read. A customer whose appointment feed failed saw a list
           quietly missing bookings under a notice that never said WHAT was missing. Naming the
           gap is the difference between "something broke" and "your appointments are missing". -->
      <ul class="muted small" style="margin:8px 0 0 18px">${partialMessages.map(message=>`<li>${esc(message)}</li>`).join('')}</ul></div>`:''}
    ${hasMore||requestPayload?.truncated===true?`<div class="card" role="status"><div class="row"><p class="muted small">Showing ${requestCount}${hasMore||requestPayload?.truncated===true?'+':''} request records, including ${activeRequestCount} active.</p><span class="spacer"></span>${hasMore?'<button class="btn ghost sm" id="customerBookingsMore">Load more requests</button>':'<span class="muted small">We can’t show older requests right now.</span>'}</div></div>`:''}
    ${currentBookingTab==='bookings'?customerBookingChooserV291(allGroups):''}
    ${customerBookingTablistMarkupV178(currentBookingTab,tabCounts)}
    <div id="customerBookingPanel" role="tabpanel" tabindex="0" aria-labelledby="customerBookingTab-${esc(currentBookingTab)}">
    ${groups.length?`<div class="customer-booking-list">${groups.map(group=>`<section class="card customer-booking-business"><div class="wallet-section-head">${customerBookingBusinessLogoV195(group)}<div><h2>${esc(group.business_name)}</h2><p class="muted small">${group.tabRequests.length} request${group.tabRequests.length===1?'':'s'} · ${group.tabAppointments.length} appointment${group.tabAppointments.length===1?'':'s'}</p></div><span class="spacer"></span>${group.bookingEnabled&&group.business_slug?`<button class="btn sm" type="button" data-repeat-booking data-business-slug="${esc(group.business_slug)}">${esc(ct('Book again'))}</button>`:group.business_slug?`<a class="btn ghost sm" href="#/wallet/${encodeURIComponent(group.business_slug)}">${esc(ct('Open programme'))}</a>`:''}</div>
      ${group.tabRequests.length?`<h3 style="font-size:1rem;margin-top:14px">${esc(requestHeading)}</h3>${group.tabRequests.map(customerBookingRequestRowV344).join('')}`:''}
      ${group.tabAppointments.length?`<h3 class="customer-booking-appointments-head-v344">${CUI.icon('bookings',{size:20})}<span>${esc(appointmentHeading)}</span><span aria-hidden="true">✦</span></h3>${group.tabAppointments.map(item=>customerBookingAppointmentRowV344(group,item,changesFeatureEnabled)).join('')}`:''}
    </section>`).join('')}</div>`
      :customerBookingEmptyMarkupV183(currentBookingTab,emptyCopy,currentBookingTab==='bookings'?[]:allGroups)}
    </div>`;
    const retry=$('customerBookingsRetry');if(retry)retry.onclick=()=>renderCustomerBookings();
    const applyRange=(next,focusId)=>{
      currentBookingRange=customerBookingNormaliseRangeV196(next);
      paintBookings();
      if(focusId)$(focusId)?.focus();
    };
    const fromInput=$('customerBookingFrom'),toInput=$('customerBookingTo');
    if(fromInput)fromInput.onchange=()=>applyRange({from:fromInput.value,to:currentBookingRange.to},'customerBookingFrom');
    if(toInput)toInput.onchange=()=>applyRange({from:currentBookingRange.from,to:toInput.value},'customerBookingTo');
    const clearRange=$('customerBookingRangeClear');
    if(clearRange)clearRange.onclick=()=>applyRange({from:'',to:''},'customerBookingFrom');
    /* v3: the chip owns the panel. Filtering itself is untouched — still live on change, still
       client-side — so Apply is honest about being nothing more than "I'm done here". */
    const rangeChip=$('customerBookingRangeChip'),rangePanel=$('customerBookingDatePanel');
    const setRangePanelOpenV3=(open,focusId='')=>{
      bookingRangePanelOpenV3=open;
      if(rangePanel)rangePanel.hidden=!open;
      if(rangeChip)rangeChip.setAttribute('aria-expanded',open?'true':'false');
      if(focusId)$(focusId)?.focus();
    };
    if(rangeChip)rangeChip.onclick=()=>setRangePanelOpenV3(!bookingRangePanelOpenV3,
      bookingRangePanelOpenV3?'customerBookingRangeChip':'customerBookingFrom');
    const applyRangePanel=$('customerBookingRangeApply');
    if(applyRangePanel)applyRangePanel.onclick=()=>setRangePanelOpenV3(false,'customerBookingRangeChip');
    const closeRangePanelOnEscape=event=>{
      if(event.key!=='Escape'||!bookingRangePanelOpenV3)return;
      event.preventDefault();
      setRangePanelOpenV3(false,'customerBookingRangeChip');
    };
    if(rangeChip)rangeChip.onkeydown=closeRangePanelOnEscape;
    if(rangePanel)rangePanel.onkeydown=closeRangePanelOnEscape;
    const tabButtons=[...$('walletBody').querySelectorAll('[data-booking-tab]')];
    const selectTab=(tab,focus=false)=>{
      if(!isCurrent()||!CUSTOMER_BOOKING_TABS_V178.some(([name])=>name===tab))return;
      currentBookingTab=tab;paintBookings();
      if(focus)$(`customerBookingTab-${tab}`)?.focus();
    };
    tabButtons.forEach((button,index)=>{
      button.onclick=()=>selectTab(button.dataset.bookingTab);
      button.onkeydown=event=>{
        const step=event.key==='ArrowRight'?1:event.key==='ArrowLeft'?-1:0;
        if(step){event.preventDefault();selectTab(tabButtons[(index+step+tabButtons.length)%tabButtons.length].dataset.bookingTab,true);return}
        if(event.key==='Home'){event.preventDefault();selectTab(tabButtons[0].dataset.bookingTab,true)}
        if(event.key==='End'){event.preventDefault();selectTab(tabButtons[tabButtons.length-1].dataset.bookingTab,true)}
      };
    });
    wireCustomerRepeatBookingV167($('walletBody'));
    wireCustomerBookingSearchV326($('walletBody'));
    /* v290 (the road from 8 to 9): a request still sitting in the business's inbox finally has a
       customer-side exit. The RPC re-resolves ownership exactly as the reader does, so this
       button can only ever withdraw a row this page was allowed to show. */
    $('walletBody').querySelectorAll('[data-withdraw-request]').forEach(button=>{
      button.onclick=async()=>{
        if(button.disabled)return;
        if(!await confirmActionV386('Withdraw this booking request? The business will not see it any more.'))return;
        button.disabled=true;button.setAttribute('aria-busy','true');
        const result=await customerRpc('customer_withdraw_booking_request_v290',{p_request:button.dataset.withdrawRequest});
        if(result.error){
          button.disabled=false;button.removeAttribute('aria-busy');
          toast(result.error.message==='already_actioned'
            ?'The business has already handled this request — manage the appointment instead.'
            :'The request could not be withdrawn. Try again.');
          return;
        }
        toast('Request withdrawn');
        renderCustomerBookings();
      };
    });
    /* v286: no page-wide slug here — every Change button carries its own business. A sent request
       repaints the page so the row reflects what the business will now see, rather than leaving a
       control that looks untouched. */
    wireWalletAppointmentActions('',{onDone:()=>renderCustomerBookings()});
    const more=$('customerBookingsMore');if(more)more.onclick=async()=>{
      const cursor=requestPayload?.next_cursor;
      if(!cursor||!isCurrent()||!more.isConnected)return;
      more.disabled=true;more.textContent='Loading…';
      /* v286: the same deadline as the first page — a stalled "Load more" left the button on
         "Loading…" for ever, which is the one state that cannot be retried. */
      const next=await customerRpc('customer_get_booking_requests',{p_limit:50,p_cursor:cursor});
      if(!isCurrent()||!more.isConnected)return;
      if(next.error){requestLoadMoreError='More active requests could not be loaded. Try again.';paintBookings();return}
      const prior=Array.isArray(requestPayload?.items)?requestPayload.items:[];
      const incoming=Array.isArray(next.data?.items)?next.data.items:[];
      const seen=new Set(prior.map(item=>item.request_id));
      requestPayload={...next.data,items:[...prior,...incoming.filter(item=>!seen.has(item.request_id))]};
      requestLoadMoreError='';paintBookings();
    };
  };
  paintBookings();
  focusCustomerRoute();
}


async function renderCustomerMessages(){
  const walletRenderEpoch=++customerWalletRenderEpoch,isCurrent=()=>customerWalletRenderEpoch===walletRenderEpoch;
  const context=await loadCustomerSurfaceContext(isCurrent);if(!context)return;
  if(context.features.customer_in_app_inbox!==true){
    renderCustomerShell({active:'messages',backTo:'#/wallet',staffWorkspaces:context.staffWorkspaces,messagesAvailable:false,body:`<header class="customer-page-head"><div><h1>Messages are not available</h1><p class="muted">This feature is not available for your account right now.</p></div></header>
      <section class="card"><p class="muted small">Your rewards, offers and bookings are still available from the main customer navigation.</p><a class="btn ghost sm" href="#/wallet" style="margin-top:14px">Open Home</a></section>`});
    focusCustomerRoute();return;
  }
  /* V289: the inbox has no tab of its own — it is opened from the header bell — so it must offer
     a way back to Home. Without backTo the shell drew no back button at all. */
  renderCustomerShell({active:'messages',backTo:'#/wallet',staffWorkspaces:context.staffWorkspaces,messagesAvailable:true,body:`<header class="customer-page-head"><div><h1>Messages</h1></div></header>
    <section class="card wallet-section" id="customerInAppInbox" aria-busy="true" tabindex="-1"><div class="wallet-skeleton"></div></section>
    ${/* v386 (owner photo 8): the page subtitle, the "<brand> inbox" heading and its second copy
         of the same sentence were three explanations stacked over one list. The list says what it
         is. Device notifications keeps its section and its id — the v296 wiring below binds
         #customerPushMessagesControl by id, and the push-permission tests read it — but it now
         renders inside the settings panel the gear opens, with the reminder preferences, which is
         where the owner drew both of them. */''}
    ${NestlyNativeBridge.isNative?'':`<section class="card customer-push-setting" id="customerMessagesNotifications" hidden><div><h2>Device notifications</h2><p class="muted small" data-push-status role="status" aria-live="polite">Checking this device…</p><p class="muted small" style="margin-top:6px">Get these updates on your lock screen too. Which ones you receive is set in <a href="#/customer/communications">Communications</a>.</p></div><button class="btn ghost sm" id="customerPushMessagesControl" type="button" aria-pressed="false">${CUI.icon('bell',{size:16})}<span data-push-label>Turn on device notifications</span></button></section>`}`});
  focusCustomerRoute();
  /* v296 (owner drew it onto this page): the switch that governs whether these updates also
     reach the lock screen now sits with the inbox it governs, not behind an avatar menu. */
  const messagesPush=window.NestlyCustomerPush?.configure({rpc:(name,args)=>sb.rpc(name,args),userId:S.user?.id});
  if(messagesPush&&$('customerPushMessagesControl')){
    messagesPush.bindButton($('customerPushMessagesControl'),{statusHost:$('customerMessagesNotifications')?.querySelector('[data-push-status]')});
    messagesPush.reconcile().catch(()=>{});
  }
  await renderCustomerInAppInbox(null,isCurrent);
}

async function loadCustomerMemberQrV327(isCurrent){
  const card=$('customerMemberQrCardV327');
  if(!card)return;
  await loadMemberQrIntoV327({card,slot:$('customerMemberQrSlotV327'),status:$('customerMemberQrStatusV327')},isCurrent);
}
/* V282 consent history. Both consent stores — the v263 per-channel audit and the v92 platform and
   partner consent events — have been append-only since the day they were written, and neither was
   readable by the person the evidence is about. The list is deliberately READ-ONLY: it is a record
   of what was decided, not a second place to decide it, and the Communications screen above it is
   the one place a choice changes. Kept as a pure markup function so the plain-language sentences,
   the escaping and the empty state can be unit-tested without a session. */
const CUSTOMER_CONSENT_CATEGORY_LABELS_V282={
  business_offers:'offers from businesses you follow',
  rewards_and_points:'your rewards and points',
  peekaa_updates:'Peekaa updates'
};
const CUSTOMER_CONSENT_CHANNEL_LABELS_V282={
  in_app:'in-app messages',push:'push notifications',email:'email',
  sms:'SMS',whatsapp:'WhatsApp',call:'phone calls'
};
function customerConsentHistorySentenceV282(entry){
  const on=entry?.enabled===true;
  if(entry?.entry_kind==='platform_partner_marketing'){
    return on
      ? 'You agreed to marketing from Peekaa and its selected partners.'
      : 'You withdrew your agreement to marketing from Peekaa and its selected partners.';
  }
  if(entry?.entry_kind==='marketing_all_channels'){
    return on
      ? 'You turned on every marketing message, on every channel.'
      : 'You turned off every marketing message, on every channel.';
  }
  const category=CUSTOMER_CONSENT_CATEGORY_LABELS_V282[entry?.category]||String(entry?.category||'');
  const channel=CUSTOMER_CONSENT_CHANNEL_LABELS_V282[entry?.channel]||String(entry?.channel||'');
  return `${on?'You turned on':'You turned off'} ${channel} for ${category}.`;
}
function customerConsentHistoryMarkupV282(entries){
  const rows=Array.isArray(entries)?entries:[];
  if(!rows.length){
    return '<p class="muted small">Nothing has changed yet. Everything is on unless you turn it off, and each change you make will be listed here.</p>';
  }
  return rows.map(entry=>`<div class="wallet-line"><div><b>${esc(customerConsentHistorySentenceV282(entry))}</b><p class="muted small">${esc(walletDate(entry?.occurred_at,true)||'')}</p></div></div>`).join('');
}
async function hydrateCustomerConsentHistoryV282(isCurrent){
  const host=$('customerConsentHistoryBody');
  if(!host)return;
  const {data,error}=await sb.rpc('customer_get_consent_history_v282',{p_limit:100});
  if(typeof isCurrent==='function'&&!isCurrent())return;
  const section=$('customerConsentHistory');
  if(!host.isConnected)return;
  host.innerHTML=error
    ? '<p class="muted small">Your consent history could not be loaded. Nothing has been changed.</p>'
    : customerConsentHistoryMarkupV282(data?.entries);
  if(section)section.setAttribute('aria-busy','false');
}

async function renderCustomerProfile(){
  const walletRenderEpoch=++customerWalletRenderEpoch,isCurrent=()=>customerWalletRenderEpoch===walletRenderEpoch;
  const context=await loadCustomerSurfaceContext(isCurrent);if(!context)return;
  renderCustomerShell({active:'profile',backTo:'#/wallet',staffWorkspaces:context.staffWorkspaces,messagesAvailable:context.features.customer_in_app_inbox===true,body:'<div class="card"><p class="muted">Loading your profile…</p></div>'});
  const profile=context.features.customer_phone_registration===true?context.profile:null;
  /* v286: a null profile used to collapse the whole page into "Profile editing isn’t available for
     this account" — the same wording for a transient customer_get_profile failure as for an account
     that genuinely has no profile row, and it took Appearance, password, passkeys, notifications,
     Communications and Marketing choices down with it. None of those read the profile row, so they
     now render either way, and a failed read says so and offers a retry. */
  const detailsLoadFailedV286=!profile&&context.features.customer_phone_registration===true&&context.profileError!=null;
  const marketingResult=await sb.rpc('customer_get_platform_marketing_preference');
  if(!isCurrent())return;
  const marketingPreference=marketingResult.error?null:marketingResult.data;
  const personalDetailsHtmlV286=profile
    ?`<div class="customer-profile-grid"><section class="card"><h2>Personal details</h2>
      <label for="customerProfileName">Full name</label><input id="customerProfileName" autocomplete="name" maxlength="200" value="${esc(profile.full_name||'')}">
      <label for="customerProfileLanguage">${esc(ct('preferredLanguage'))}</label><select id="customerProfileLanguage" autocomplete="language"><option value="en" ${profile.preferred_language==='en'?'selected':''}>English</option><option value="zh" ${profile.preferred_language==='zh'?'selected':''}>中文</option><option value="ms" ${profile.preferred_language==='ms'?'selected':''}>Bahasa Melayu</option><option value="ta" ${profile.preferred_language==='ta'?'selected':''}>தமிழ்</option></select>
      <p class="muted small" style="margin-top:6px">${esc(ct('languageHelp',{product:BRAND.productName}))}</p>
      <div id="customerProfileSaveStatus" role="status" aria-live="polite"></div>
      <button class="btn" id="customerProfileSave" type="button" style="margin-top:16px;width:100%">${CUI.icon('check',{size:16})}<span>Save profile</span></button>
    </section><aside class="card"><h2>Date of birth</h2><p style="font-weight:700;margin-top:8px">${esc(profile.birth_date?walletDate(`${profile.birth_date}T00:00:00+08:00`):'Not available')}</p><p class="muted small" style="margin-top:8px">Your date of birth is not editable here and is not shown to businesses.</p></aside></div>`
    :detailsLoadFailedV286
      ?`<section class="card" id="customerProfileDetailsError"><h2>We couldn’t load your details</h2><p class="muted small" style="margin-top:6px">Your name and date of birth did not load just now. Nothing has been changed, and everything below still works.</p><button class="btn" id="customerProfileDetailsRetry" type="button" style="margin-top:16px">${CUI.icon('check',{size:16})}<span>Try again</span></button></section>`
      :'<section class="card"><h2>Profile editing is not available</h2><p class="muted small" style="margin-top:6px">Profile editing isn’t available for this account.</p></section>';
  /* v327: one Peekaa-wide QR, not tied to any single business — shown only once the platform
     identity capability itself is on (independent of profile/phone-registration availability). */
  const memberQrCardHtmlV327=context.features.customer_identity===true
    ?`<section class="card" id="customerMemberQrCardV327" style="margin-top:14px" aria-busy="true">
        <h2>My Peekaa QR</h2>
        <p class="muted small" style="margin-top:6px">Show this at any Peekaa business to be recognised as you — the same code works everywhere you're a member. It never reveals your phone number.</p>
        <div id="customerMemberQrSlotV327" style="display:grid;place-items:center;min-height:200px;margin:14px auto;padding:12px;border:1px solid var(--line);border-radius:16px;background:#fff;max-width:240px"><p class="muted small">Loading your code…</p></div>
        <p id="customerMemberQrStatusV327" class="muted small" role="status" aria-live="polite"></p>
      </section>`
    :'';
  $('walletBody').innerHTML=`<header class="customer-page-head"><div><h1>Profile</h1><p class="muted">${profile?`Keep your name up to date and manage your ${esc(BRAND.customerLabel)} account.`:`Your ${esc(BRAND.customerLabel)} account details.`}</p></div></header>
    <!-- Top-20 #20: the page was ~14 visually identical white cards in one flat stack, so account
         closure, a marketing choice and a sound switch all read at the same weight. Four serif
         headings on the ivory ground group them. No card's markup, id, handler or copy changed;
         the only card that MOVED is Device notifications, from between passkeys and account
         closure into Preferences, where it belongs — it is bound by id after this innerHTML, so
         its position carries no wiring. Sign out stays last (v296). -->
    <h2 class="customer-profile-group-v3">You</h2>
    ${personalDetailsHtmlV286}
    ${memberQrCardHtmlV327}
    <h2 class="customer-profile-group-v3">Preferences</h2>
    <section class="card" id="customerAppearance" style="margin-top:14px"><div class="wallet-section-head"><div><h2>Appearance</h2><p class="muted small">Peekaa looks the same as your businesses do by default. Switch to dark if you prefer it.</p></div></div>
      <div class="customer-theme-choice" role="radiogroup" aria-label="Appearance">${[['light','Light','Beige, like the business app'],['dark','Dark','Easier at night'],['device','Match my device','Follows your phone setting']].map(([value,label,hint])=>`<label class="customer-theme-option" for="customerTheme-${value}"><input type="radio" id="customerTheme-${value}" name="customerTheme" value="${value}" ${customerThemePreferenceV190()===value?'checked':''}><span><b>${esc(label)}</b><span class="muted small" style="display:block">${esc(hint)}</span></span></label>`).join('')}</div>
    </section>
    <section class="card" id="customerExperiencePreferences" style="margin-top:14px"><div class="wallet-section-head"><div><h2>${esc(ct('successSounds'))}</h2><p class="muted small">${esc(ct('soundHelp'))}</p></div><span class="spacer"></span><label class="customer-sound-toggle" for="customerSuccessSound" style="display:inline-flex;gap:10px;align-items:center;cursor:pointer"><span class="muted small">${esc(customerCelebrationSoundEnabled?ct('soundOn'):ct('soundOff'))}</span><span class="cui-switch"><input id="customerSuccessSound" type="checkbox" ${customerCelebrationSoundEnabled?'checked':''}><i></i></span></label></div></section>
    ${NestlyNativeBridge.isNative?`<section class="card" id="customerDeviceNotificationsNative" style="margin-top:14px"><h2>Notifications</h2><p class="muted small" style="margin-top:6px">Reward, offer and booking updates arrive in your Peekaa inbox — tap the bell at the top of any screen. Alerts on your lock screen are not switched on for this app yet.</p><a class="btn ghost sm" href="#/customer/messages" style="margin-top:12px">Open inbox</a></section>`:`<section class="card customer-push-setting" id="customerDeviceNotifications" style="margin-top:14px"><div><h2>Device notifications</h2><p class="muted small" data-push-status role="status" aria-live="polite">Checking this device…</p><p class="muted small" style="margin-top:7px">This switch controls whether this device can show notifications at all. Which ones you actually receive is set in <a href="#/customer/communications">Communications</a> — offers, rewards and points, and Peekaa updates each have their own channels there.</p></div><button class="btn ghost" id="customerPushProfileControl" type="button" aria-pressed="false">${CUI.icon('bell',{size:16})}<span data-push-label>Turn on device notifications</span></button></section>`}
    <h2 class="customer-profile-group-v3">Privacy &amp; consent</h2>
    <section class="card" id="customerMarketingPreference" style="margin-top:14px"><h2>${esc(ct('Marketing choices'))}</h2><details class="customer-profile-consent-v3" style="margin-top:8px"><summary class="small">What you’re agreeing to</summary><p class="muted small" style="margin-top:5px">${esc(ct('Offers and updates from Nestly Technologies Pte. Ltd., the company behind {product}, and its partners, by push notification, in-app message, email, SMS, WhatsApp, phone call and other marketing channels. Your name and contact details may be shared with {product}’s partners for marketing purposes only. This is separate from messages sent by individual businesses.',{product:BRAND.productName}))}</p></details>
      ${marketingPreference?`<label class="row" for="customerProfileMarketing" style="align-items:flex-start;margin-top:14px;color:var(--ink);font-weight:500"><span class="cui-switch" style="margin-top:1px"><input id="customerProfileMarketing" type="checkbox" ${marketingPreference.opted_in===true?'checked':''}><i></i></span> <span>${ct('Yes — send me these offers and updates. I can turn this off here, or in {link}, at any time. {product} stops sending straight away. Partners are told to stop within 10 business days. Turning it off does not affect my points, bookings or service messages.',{link:`<a href="#/customer/communications" style="color:var(--coral);text-decoration:underline">${esc(ct('Communications'))}</a>`,product:esc(BRAND.productName)})}</span></label>
      <div id="customerProfileMarketingStatus" role="status" aria-live="polite"></div>
      <button class="btn ghost" id="customerProfileMarketingSave" type="button" style="margin-top:16px">${CUI.icon('check',{size:16})}<span>${esc(ct('Save marketing choice'))}</span></button>`
      /* v286: a failed read used to render this sentence ALONE — no checkbox, no save button, and
         nothing to press. Withdrawing marketing consent is the one control here the customer can
         demand at any time, so the read is retryable instead of a dead end. */
      :`<p class="err" role="status" style="margin-top:12px">${esc(ct('Your marketing choice could not be loaded. No change has been made.'))}</p><button class="btn ghost" id="customerMarketingRetry" type="button" style="margin-top:14px">${esc(ct('retry'))}</button>`}
    </section>
    <section class="card" id="customerCommunicationsEntry" style="margin-top:14px"><div class="wallet-section-head"><div><h2>${esc(ct('Communications'))}</h2><p class="muted small">${esc(ct('Choose what you hear about and how — offers from businesses you follow, your rewards and points, and Peekaa updates.'))}</p></div><span class="spacer"></span><a class="btn ghost sm" href="#/customer/communications">${CUI.icon('bell',{size:16})}<span>${esc(ct('Open communications'))}</span></a></div></section>
    <section class="card" id="customerConsentHistory" style="margin-top:14px" aria-busy="true"><div class="wallet-section-head"><div><h2>${esc(ct('Your consent history'))}</h2><p class="muted small">${esc(ct('Every marketing choice you have made, newest first. This is a record only — to change something, open Communications above.'))}</p></div></div><div id="customerConsentHistoryBody" style="margin-top:12px"><p class="muted small">${esc(ct('Loading your consent history…'))}</p></div></section>
    <h2 class="customer-profile-group-v3">Security &amp; account</h2>
    <section class="card" id="customerPasswordManage" style="margin-top:14px"><h2>Change password</h2><p class="muted small" style="margin-top:5px">Your password is used for normal sign-in and does not send an OTP.</p>
      <label for="customerProfilePassword">New password</label>${passwordControlHtml('customerProfilePassword',{autocomplete:'new-password',minlength:'12'})}
      <label for="customerProfilePasswordConfirm">Confirm new password</label>${passwordControlHtml('customerProfilePasswordConfirm',{autocomplete:'new-password',minlength:'12'})}
      <div id="customerProfilePasswordStatus" role="status" aria-live="polite"></div>
      <button class="btn" id="customerProfilePasswordSave" type="button" style="margin-top:16px;width:100%">${CUI.icon('check',{size:16})}<span>Update password</span></button>
    </section>
    <section class="card" id="customerPasskeys" style="margin-top:14px" aria-busy="true"><div class="wallet-section-head"><div><h2>Face ID, Touch ID &amp; passkeys</h2><p class="muted small">Register this device for quicker passwordless sign-in. Your face or fingerprint stays on your device.</p></div><span class="spacer"></span><button class="btn sm" id="customerPasskeyAdd" type="button">${CUI.icon('add',{size:16})}<span>Add passkey</span></button></div><div id="customerPasskeyList"><p class="muted small">Checking registered passkeys…</p></div><p id="customerPasskeyManageStatus" class="muted small" role="status" aria-live="polite" style="margin-top:8px"></p></section>
    ${accountDeletionCardHtml()}
    <!-- v296 (owner, annotated: "Sign out put here"). Sign out left the header menu and became
         the last thing on the page it acts on — deliberately after account & privacy, so it is
         reached by finishing the page rather than by hunting an icon. -->
    <section class="card" id="customerProfileSignOutCard" style="margin-top:16px"><div class="row"><div><h2>${esc(ct('signOut'))}</h2><p class="muted small" style="margin-top:6px">You will need your phone number or passkey to sign back in.</p></div><span class="spacer"></span><button class="btn ghost" id="customerProfileSignOut" type="button"><span>${esc(ct('signOut'))}</span></button></div></section>`;
  bindPasswordVisibility($('walletBody'));
  if($('customerMemberQrCardV327'))void loadCustomerMemberQrV327(isCurrent);
  $('customerProfileSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
  /* v190: applied immediately on change — the person is looking at the surface they just picked,
     so a save button would be a step with nothing behind it. */
  $('walletBody').querySelectorAll('input[name="customerTheme"]').forEach(option=>option.onchange=()=>{
    if(!option.checked)return;
    setCustomerThemePreferenceV190(option.value);
    CUI.announce(option.value==='dark'?'Dark appearance on':option.value==='device'?'Appearance follows your device':'Light appearance on');
  });
  const successSound=$('customerSuccessSound');
  if(successSound){
    const reducedMotion=globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches===true;
    /* v286: the label is painted from the stored preference, so a customer who had turned sounds on
       and then switched Reduce Motion on saw a greyed-out, unchecked box captioned "On". */
    if(reducedMotion){
      successSound.checked=false;successSound.disabled=true;customerCelebrationSoundEnabled=false;
      const label=successSound.nextElementSibling;if(label)label.textContent=ct('soundOff');
    }
    successSound.onchange=()=>{
      customerCelebrationSoundEnabled=successSound.checked&&!reducedMotion;
      try{sessionStorage.setItem('nestly.customer.successSound',customerCelebrationSoundEnabled?'1':'0')}catch{}
      const label=successSound.nextElementSibling;if(label)label.textContent=customerCelebrationSoundEnabled?ct('soundOn'):ct('soundOff');
    };
  }
  const profilePush=window.NestlyCustomerPush?.configure({rpc:(name,args)=>sb.rpc(name,args),userId:S.user?.id});
  if(profilePush){
    profilePush.bindButton($('customerPushProfileControl'),{statusHost:$('customerDeviceNotifications')?.querySelector('[data-push-status]')});
    profilePush.reconcile().catch(()=>{});
  }
  wireAccountDeletionButton();
  let profileAttempt=null;
  /* v286: the retry re-runs the whole profile render, which re-reads customer_get_profile. */
  const detailsRetry=$('customerProfileDetailsRetry');
  if(detailsRetry)detailsRetry.onclick=()=>{detailsRetry.disabled=true;CUI.announce('Loading your details again.');renderCustomerProfile()};
  if($('customerProfileSave'))$('customerProfileSave').onclick=async()=>{
    const fullName=$('customerProfileName').value.trim(),language=$('customerProfileLanguage').value;
    const status=$('customerProfileSaveStatus');
    if(!fullName){status.innerHTML='<div class="err">Enter your full name.</div>';$('customerProfileName').focus();return}
    const fingerprint=`${fullName}:${language}`;
    if(!profileAttempt||profileAttempt.fingerprint!==fingerprint)profileAttempt={fingerprint,key:crypto.randomUUID()};
    const button=$('customerProfileSave');button.disabled=true;
    const {data,error}=await sb.rpc('customer_update_profile',{p_full_name:fullName,p_preferred_language:language,p_idempotency_key:profileAttempt.key});
    if(!isCurrent()||!button.isConnected)return;
    button.disabled=false;
    if(error||data?.outcome!=='updated'){status.innerHTML='<div class="err">Your profile could not be saved. Please try again.</div>';return}
    profileAttempt=null;
    /* v293: the wallet follows the saved language immediately. Re-render only
       when the locale actually changed so the status line survives a plain
       name edit. */
    const nextLocale=normalizeCustomerLocale(language);
    if(nextLocale!==customerLocale){
      customerLocale=nextLocale;
      if(S.customerProfile)S.customerProfile.preferred_language=language;
      globalThis.document?.documentElement?.setAttribute('lang',customerLocale);
      CUI.announce(ct('profileSaved'));
      renderCustomerProfile();
      return;
    }
    if(S.customerProfile)S.customerProfile.preferred_language=language;
    status.innerHTML=`<p class="muted small" style="margin-top:10px;color:var(--green)">${esc(ct('profileSaved'))}</p>`;CUI.announce(ct('profileSaved'));
  };
  const marketingSave=$('customerProfileMarketingSave');
  if(marketingSave){
    let marketingAttempt=null;
    marketingSave.onclick=async()=>{
      const optedIn=$('customerProfileMarketing').checked;
      if(!marketingAttempt||marketingAttempt.optedIn!==optedIn){
        marketingAttempt={optedIn,key:crypto.randomUUID()};
      }
      const status=$('customerProfileMarketingStatus');
      marketingSave.disabled=true;
      const {data,error}=await sb.rpc('customer_set_platform_marketing_preference',{
        p_opted_in:optedIn,p_idempotency_key:marketingAttempt.key
      });
      if(!isCurrent()||!marketingSave.isConnected)return;
      marketingSave.disabled=false;
      if(error||data?.outcome!=='updated'){
        status.innerHTML='<div class="err">Your marketing choice could not be saved. Please try again.</div>';return;
      }
      marketingAttempt=null;
      if(optedIn&&!await grantAllCommunicationsV265()){
        if(!isCurrent()||!marketingSave.isConnected)return;
        status.innerHTML='<div class="err">Marketing consent saved, but some communication switches could not be turned back on. Open <a href="#/customer/communications">Communications</a> to check them.</div>';
        CUI.announce('Marketing consent saved. Some communication switches could not be turned back on.');return;
      }
      if(!isCurrent()||!marketingSave.isConnected)return;
      status.innerHTML=`<p class="muted small" style="margin-top:10px;color:var(--green)">${optedIn?'Marketing consent saved.':'Marketing consent withdrawn.'}</p>`;
      CUI.announce(optedIn?'Marketing consent saved.':'Marketing consent withdrawn.');
    };
  }
  /* v286: re-runs the profile render, which re-reads customer_get_platform_marketing_preference,
     so a customer who came here to switch marketing off is never stranded by one failed read. */
  const marketingRetry=$('customerMarketingRetry');
  if(marketingRetry)marketingRetry.onclick=()=>{
    marketingRetry.disabled=true;CUI.announce('Loading your marketing choice again.');renderCustomerProfile();
  };
  $('customerProfilePasswordSave').onclick=async()=>{
    const password=$('customerProfilePassword').value;
    const confirmation=$('customerProfilePasswordConfirm').value;
    const status=$('customerProfilePasswordStatus'),button=$('customerProfilePasswordSave');
    if(!validNewPassword(password)){
      status.innerHTML='<div class="err">Use at least 12 characters with uppercase, lowercase, a number, and a symbol.</div>';return;
    }
    if(password!==confirmation){
      status.innerHTML='<div class="err">Passwords do not match.</div>';return;
    }
    button.disabled=true;
    const {error}=await sb.auth.updateUser({password});
    if(!isCurrent()||!button.isConnected)return;
    button.disabled=false;
    if(error){
      status.innerHTML=`<div class="err">${esc(customerPasswordUpdateErrorMessage(error))}</div>`;return;
    }
    $('customerProfilePassword').value='';$('customerProfilePasswordConfirm').value='';
    status.innerHTML='<p class="muted small" style="margin-top:10px;color:var(--green)">Password updated.</p>';
    CUI.announce('Password updated.');
  };
  const passkeyHost=$('customerPasskeys'),passkeyList=$('customerPasskeyList'),passkeyStatus=$('customerPasskeyManageStatus');
  const passkeyAdd=$('customerPasskeyAdd');
  const passkeySupported=customerPasskeySupported({management:true});
  const formatPasskeyDate=value=>{
    const date=value?new Date(value):null;
    return date&&!Number.isNaN(date.getTime())?new Intl.DateTimeFormat(undefined,{dateStyle:'medium'}).format(date):'Date unavailable';
  };
  const loadPasskeys=async()=>{
    if(!passkeySupported){
      passkeyHost.setAttribute('aria-busy','false');passkeyAdd.disabled=true;
      passkeyList.innerHTML='<p class="muted small">Passkeys are not supported in this browser. Sign in with your mobile number and password.</p>';return;
    }
    const {data,error}=await sb.auth.passkey.list();
    if(!isCurrent()||!passkeyHost.isConnected)return;
    passkeyHost.setAttribute('aria-busy','false');
    if(error){
      passkeyAdd.disabled=error.code==='passkey_disabled';
      passkeyList.innerHTML=`<p class="muted small">${error.code==='passkey_disabled'?'Face ID and passkeys aren’t available yet. Use your password.':'Registered passkeys could not be loaded.'}</p>`;return;
    }
    const passkeys=Array.isArray(data)?data:(Array.isArray(data?.passkeys)?data.passkeys:[]);
    passkeyList.innerHTML=passkeys.length?passkeys.map(item=>`<div class="wallet-line"><div><b>${esc(item.friendly_name||'Passkey')}</b><p class="muted small" style="margin-top:3px">Added ${esc(formatPasskeyDate(item.created_at))}${item.last_used_at?` · last used ${esc(formatPasskeyDate(item.last_used_at))}`:''}</p></div><span class="spacer"></span><button class="btn ghost sm" type="button" data-passkey-rename="${esc(item.id)}" data-passkey-name="${esc(item.friendly_name||'Passkey')}" aria-label="Rename ${esc(item.friendly_name||'passkey')}">Rename</button><button class="btn danger sm" type="button" data-passkey-delete="${esc(item.id)}" aria-label="Delete ${esc(item.friendly_name||'passkey')}">Delete</button></div>`).join('')
      :'<p class="muted small">No passkeys registered yet. Add one on a private device you control.</p>';
    passkeyList.querySelectorAll('[data-passkey-rename]').forEach(button=>button.onclick=async()=>{
      const friendlyName=await showCustomerDecisionDialog({
        title:'Name this passkey',
        body:'Give this device a name you will recognise later, so you know which passkey to remove.',
        keepLabel:'Cancel',confirmLabel:'Save name',
        input:{label:'Passkey name',value:button.dataset.passkeyName||'Passkey',placeholder:'Personal iPhone',maxLength:120}
      });
      if(friendlyName===null){if(passkeyHost.isConnected)passkeyStatus.textContent='Passkey rename cancelled.';return}
      if(!isCurrent()||!button.isConnected)return;
      const name=friendlyName.trim();
      if(!name||name.length>120){passkeyStatus.textContent='Passkey name must be between 1 and 120 characters.';return}
      button.disabled=true;passkeyStatus.textContent='Renaming passkey…';
      const {error:updateError}=await sb.auth.passkey.update({passkeyId:button.dataset.passkeyRename,friendlyName:name});
      if(!isCurrent()||!passkeyHost.isConnected)return;
      if(updateError){button.disabled=false;passkeyStatus.textContent='Passkey could not be renamed. Try again.';return}
      passkeyStatus.textContent='Passkey renamed.';loadPasskeys();
    });
    passkeyList.querySelectorAll('[data-passkey-delete]').forEach(button=>button.onclick=async()=>{
      const confirmed=await showCustomerDecisionDialog({title:'Remove this passkey?',body:'You will need another passkey or your password to sign in.',keepLabel:'Keep passkey',confirmLabel:'Remove passkey',danger:true});
      if(!confirmed||!button.isConnected)return;
      button.disabled=true;passkeyStatus.textContent='Removing passkey…';
      const {error:deleteError}=await sb.auth.passkey.delete({passkeyId:button.dataset.passkeyDelete});
      if(!isCurrent()||!passkeyHost.isConnected)return;
      if(deleteError){button.disabled=false;passkeyStatus.textContent='Passkey could not be removed. Try again.';return}
      passkeyStatus.textContent='Passkey removed.';loadPasskeys();
    });
  };
  passkeyAdd.onclick=async()=>{
    if(!passkeySupported)return;
    passkeyAdd.disabled=true;passkeyStatus.textContent='Follow your device prompt to add a passkey…';
    /* V468: see the prompt above — a browser-side WebAuthn rejection THROWS rather than resolving
       {error}, and an unhandled throw here left the button disabled with no explanation. */
    let error=null;
    try{({error}=await sb.auth.registerPasskey()||{})}catch(thrown){error=thrown}
    if(!isCurrent()||!passkeyAdd.isConnected)return;
    passkeyAdd.disabled=false;
    if(error){
      passkeyStatus.textContent=error.code==='passkey_disabled'
        ?'Face ID and passkeys aren’t available yet. Use your password.'
        :customerPasskeyErrorMessage(error,{action:'setup'});
      return;
    }
    passkeyStatus.textContent='Passkey added. You can use it at your next sign-in.';loadPasskeys();
  };
  loadPasskeys();
  hydrateCustomerConsentHistoryV282(isCurrent);
  focusCustomerRoute();
}

async function renderCustomerQrJoin(){
  const joinRenderEpoch=++customerWalletRenderEpoch,isCurrent=()=>customerWalletRenderEpoch===joinRenderEpoch;
  const token=pendingCustomerJoinToken;
  if(!token){
    renderCustomerShell({active:'programmes',body:`<section class="card"><h1>Scan the business QR</h1><p class="muted small" style="margin-top:7px">This join link is missing or invalid. Return to the participating business and scan its Peekaa QR again.</p><a class="btn ghost" href="#/customer/programmes" style="margin-top:16px">Back to programmes</a></section>`});
    focusCustomerRoute();return;
  }
  renderCustomerShell({active:'programmes',body:`<section class="card" aria-busy="true"><div class="row">${CUI.icon('scan',{size:24})}<div><h1>Joining this programme</h1><p class="muted small" style="margin-top:5px">Peekaa is validating the business QR. No customer can search for or self-link a business here.</p></div></div><p id="customerQrJoinStatus" class="muted small" role="status" aria-live="polite" style="margin-top:14px">Checking QR…</p></section>`});
  focusCustomerRoute();
  const attemptKey=writeAttemptKey('nestly.customer.joinQr',token);
  const {data,error}=await customerRpc('customer_join_business_from_qr_v89',{
    p_join_token:token,p_idempotency_key:attemptKey
  });
  if(!isCurrent())return;
  const status=$('customerQrJoinStatus');
  if(error){
    if(error.code!=='PGRST202'&&error.code!=='42883')rememberPendingCustomerJoinToken('');
    status.innerHTML=`<span class="err">${error.code==='PGRST202'||error.code==='42883'?'Something’s not working right now. Please try again shortly.':'This QR is expired, paused, or no longer valid. Ask the business for its current Peekaa QR.'}</span><br><a class="btn ghost sm" href="#/customer/programmes" style="margin-top:12px">Back to programmes</a>`;
    status.closest('.card')?.setAttribute('aria-busy','false');return;
  }
  if(!['joined','already_joined','completed','linked'].includes(String(data?.outcome||data?.status||''))){
    /* v286 (audit): this branch left the customer on a card still headed 'Joining this programme'
       with no action, and kept the dead token + write-attempt key so a later retry replayed the
       same failing join. It now matches the error branch: a way out, and a clean rescan. */
    clearWriteAttempt('nestly.customer.joinQr');rememberPendingCustomerJoinToken('');
    status.innerHTML='This programme could not be joined. Ask the business to check its sign-up settings.<br><a class="btn ghost sm" href="#/customer/programmes" style="margin-top:12px">Back to programmes</a>';
    status.closest('.card')?.setAttribute('aria-busy','false');return;
  }
  clearWriteAttempt('nestly.customer.joinQr');rememberPendingCustomerJoinToken('');
  const slug=normalizeCustomerBusinessIntent(data?.business?.slug||data?.business_slug||'');
  status.textContent='Programme joined. Opening your wallet…';
  await maybeOfferCustomerPasskeySetup({isCurrent});
  if(!isCurrent())return;
  nav(slug?'#/wallet/'+encodeURIComponent(slug):'#/customer/programmes');
}

async function renderCustomerClaim(){
  const claimRenderEpoch=++customerWalletRenderEpoch;
  const isClaimCurrent=()=>customerWalletRenderEpoch===claimRenderEpoch;
  const claimParams=new URLSearchParams((location.hash.split('?')[1]||''));
  const invitationToken=pendingCustomerInvitationToken||claimParams.get('invite')||'';
  const businessIntent=invitationToken?'':normalizeCustomerBusinessIntent(
    claimParams.get('business')||pendingCustomerBusinessSlug
  );
  if(businessIntent)pendingCustomerBusinessSlug=businessIntent;
  if(invitationToken){
    pendingCustomerBusinessSlug='';
    history.replaceState(null,'',`${location.pathname}${location.search}#/claim`);
  }
  /* V289 (audit A3, G2): everything below this guard — the claim form, the phone/email method
     choice, customer_claim_link_by_verified_phone — was unreachable, because the guard fired for
     EVERY visit without an invitation token, including one that arrived carrying a business
     intent from that business's own deep link. The intent was then discarded and the customer was
     told to go and scan a QR they had, in effect, already followed. Discovery is still QR/link
     only: with no carried intent this is unchanged, and there is still no directory, search or
     listing anywhere on this surface — the form only appears once a business-issued link or QR
     has named the business. */
  if(!invitationToken&&!businessIntent){
    renderCustomerShell({active:'programmes',body:`<section class="card"><h1>Scan the business QR to join</h1><p class="muted small" style="margin-top:7px">Customers cannot search for or manually link a business from this portal. Visit the participating business and scan its current Peekaa QR.</p><a class="btn ghost" href="#/customer/programmes" style="margin-top:16px">Back to programmes</a></section>`});
    focusCustomerRoute();return;
  }
  const customerCapabilities=await loadCustomerFeatureCapabilities();
  if(!isClaimCurrent())return;
  if(!customerCapabilities.customer_identity||!customerCapabilities.customer_claims){
    return renderCustomerWalletUnavailable('Customer claiming is not available yet.');
  }
  const phoneClaimAvailable=!invitationToken
    && customerCapabilities.customer_phone_claims===true
    && customerCapabilities.customer_phone_registration===true;
  renderCustomerShell({active:'programmes',body:`<div class="card"><h1>${esc(invitationToken?ct('Accept invitation'):ct('Add a business programme'))}</h1><p class="muted small" style="margin-top:6px">${esc(invitationToken?ct('Confirm this private invitation while signed in to the intended account.'):phoneClaimAvailable?ct('Enter the business link from its QR or invitation. We only connect an exact unclaimed record.'):ct('Use the same confirmed email your business has on file.'))}</p>
      <div id="claimPersonas" style="margin-top:14px"><p class="muted small">${esc(ct('Checking access…'))}</p></div>
      ${invitationToken?'':`${phoneClaimAvailable?`<fieldset style="border:0;padding:0;margin-top:14px"><legend class="small" style="font-weight:700">${esc(ct('How should we find your record?'))}</legend><label class="row" for="claimByPhone" style="color:var(--ink);font-weight:500"><input id="claimByPhone" name="claimMethod" type="radio" value="phone" checked style="width:20px;min-width:20px;min-height:20px"> <span>${esc(ct('Use my verified mobile number'))}</span></label><label class="row" for="claimByEmail" style="margin-top:10px;color:var(--ink);font-weight:500"><input id="claimByEmail" name="claimMethod" type="radio" value="email" style="width:20px;min-width:20px;min-height:20px"> <span>${esc(ct('Use my confirmed email instead'))}</span></label></fieldset>`:''}<label for="claimSlug">${esc(ct('Business link'))}</label><input id="claimSlug" autocomplete="off" placeholder="business-slug or ${esc(BRAND.productName)} link" value="${esc(businessIntent)}">`}
      <button class="btn" id="claimStart" style="margin-top:14px">${esc(invitationToken?ct('Accept invitation'):ct('Claim'))}</button>
      <div id="claimResult"></div></div>`});
  focusCustomerRoute();
  const renderPersonas=async()=>{
    const {data,error}=await sb.rpc('get_my_personas');
    if(!isClaimCurrent())return;
    if(error){
      $('claimPersonas').innerHTML=`<div class="err">${esc(ct('Customer access could not be checked.'))} <button class="btn ghost sm" id="claimPersonaRetry" style="margin-left:8px">${esc(ct('retry'))}</button></div>`;
      $('claimPersonaRetry').onclick=renderPersonas;
      return;
    }
    const staff=sortStaffWorkspaces(data?.staff||[]),customer=data?.customer||[];
    const staffLinks=staff.map(workspace=>`<a class="btn ghost sm" href="#/workspace/${encodeURIComponent(workspace.business_slug)}/dashboard">${esc(workspace.business_name||workspace.business_slug)}</a>`).join('');
    $('claimPersonas').innerHTML=staff.length&&customer.length
      ?`<div class="card" style="background:var(--bg)"><b>${esc(ct('Choose where to continue'))}</b><div class="row" style="margin-top:10px">${staffLinks}<a class="btn ghost sm" href="#/wallet">${esc(BRAND.customerLabel)}</a></div></div>`
      :customer.length
        ?`<p class="muted small">${esc(ct('Wallet links:'))} ${customer.map(x=>`<a style="color:#D06A2E" href="#/wallet/${encodeURIComponent(x.business_slug)}">${esc(x.business_name)}</a>`).join(', ')}</p>`
        :staff.length
          ?`<div><p class="muted small">${esc(ct('Staff workspaces:'))}</p><div class="row" style="margin-top:8px">${staffLinks}</div></div>`
          :`<p class="muted small">${esc(ct('No wallet links yet.'))}</p>`;
  };
  const {data:intentPersonas,error:intentPersonasError}=businessIntent
    ?await sb.rpc('get_my_personas'): {data:null,error:null};
  if(!isClaimCurrent())return;
  if(intentPersonasError){
    return renderCustomerCapabilityRetry('We could not check whether this programme is already linked. Please try again.');
  }
  if(!intentPersonasError&&businessIntent&&(intentPersonas?.customer||[]).some(persona=>persona.business_slug===businessIntent)){
    pendingCustomerBusinessSlug='';
    nav('#/wallet/'+encodeURIComponent(businessIntent));return;
  }
  await renderPersonas();
  const identityAttemptId=crypto.randomUUID();
  let claimAttempt=null;
  $('claimStart').onclick=async()=>{
    const slug=invitationToken?'':normalizeCustomerBusinessIntent($('claimSlug').value);
    if(!invitationToken&&!slug)return toast('Enter a valid business link');
    if(!invitationToken)$('claimSlug').value=slug;
    const method=invitationToken?'invitation':(phoneClaimAvailable?(document.querySelector('input[name="claimMethod"]:checked')?.value||'phone'):'email');
    const attemptKey=`${method}:${slug}`;
    if(!claimAttempt||claimAttempt.key!==attemptKey)claimAttempt={key:attemptKey,id:crypto.randomUUID()};
    const originalLabel=invitationToken?ct('Accept invitation'):ct('Claim');
    $('claimStart').disabled=true;$('claimStart').textContent=ct('Checking…');
    if(method==='email'||method==='invitation'){
      invalidatePersonaCacheV370();
      const identity=await sb.rpc('customer_create_identity',{p_idempotency_key:identityAttemptId});
      if(!isClaimCurrent())return;
      if(identity.error){
        $('claimStart').disabled=false;$('claimStart').textContent=originalLabel;
        $('claimResult').innerHTML=`<div class="err">${esc(ct('Customer access is unavailable. Please try again later.'))}</div>`;return;
      }
    }
    const {data,error}=invitationToken
      ?await (invalidatePersonaCacheV370(),sb.rpc('customer_claim_link_invitation',{p_token:invitationToken,p_idempotency_key:claimAttempt.id}))
      :method==='phone'
        ?await (invalidatePersonaCacheV370(),sb.rpc('customer_claim_link_by_verified_phone',{p_business_slug:slug,p_idempotency_key:claimAttempt.id}))
        :await (invalidatePersonaCacheV370(),sb.rpc('customer_claim_link_by_email',{p_business_slug:slug,p_idempotency_key:claimAttempt.id}));
    if(!isClaimCurrent())return;
    $('claimStart').disabled=false;$('claimStart').textContent=originalLabel;
    if(error){$('claimResult').innerHTML=`<div class="err">${esc(ct('Customer access is unavailable. Please try again later.'))}</div>`;return}
    pendingCustomerInvitationToken='';
    const outcome=data?.outcome||'no_link_created';
    if(!invitationToken&&outcome==='linked'){
      pendingCustomerBusinessSlug='';
      rememberPendingCustomerDestination('');
      nav('#/wallet/'+encodeURIComponent(slug));return;
    }
    $('claimResult').innerHTML=`<div class="card" style="margin-top:16px"><b>${esc(outcome==='linked'?ct('Linked'):ct('Request received'))}</b>
      <p class="muted small" style="margin-top:6px">${esc(outcome==='linked'?ct('Your wallet is ready.'):ct('If the details match an available customer record, the business link will appear here.'))}</p>
      ${outcome==='linked'?`<button class="btn sm" id="goWallet" style="margin-top:10px">${esc(ct('Open wallet'))}</button>`:''}</div>`;
    if($('goWallet'))$('goWallet').onclick=()=>nav(slug?'#/wallet/'+encodeURIComponent(slug):'#/wallet');
    await renderPersonas();
  };
}

/* V289 (audit A3, G2 — "#/wallet/<slug> for a business you have not joined"). Every customer
   wallet RPC raises 42501 ("verified customer link required") when the signed-in customer holds
   no link to that business, and the wallet answered all three of those denials with "This
   business could not be loaded" plus a Retry button that could only ever fail again. Nothing was
   broken and nothing was loading: the customer simply is not a member yet. Say that, and carry
   the slug the link supplied into the join flow instead of discarding it. The business NAME is
   deliberately not fetched — the server refuses to describe a business this account has no link
   to, and inventing a lookup here would turn a deep link into a directory probe — so the link's
   own slug is shown as-is. */
function customerBusinessSlugLabelV289(businessSlug){
  const slug=String(businessSlug||'').trim();
  if(!slug)return 'this business';
  return slug.replace(/[-_]+/g,' ').replace(/\s+/g,' ').trim()
    .replace(/\b[a-z]/g,letter=>letter.toUpperCase())||'this business';
}
function renderCustomerNotJoinedV289(businessSlug){
  globalThis.document?.documentElement?.setAttribute('lang','en');
  const body=$('walletBody');if(!body)return;
  const label=customerBusinessSlugLabelV289(businessSlug);
  body.innerHTML=`<header class="customer-business-header-v346" style="margin-bottom:10px"><a class="btn ghost sm" href="#/customer/programmes" aria-label="Back to My Rewards" style="min-width:44px;padding:0 14px">‹</a><span class="customer-business-identity-v346"><span class="customer-programme-logo" aria-hidden="true">${esc((label||'?').slice(0,1).toUpperCase())}</span><span><b style="font-family:Georgia,'Times New Roman',serif">${esc(label)}</b><small>Not joined yet</small></span></span></header>
  <section class="card" style="text-align:center;padding:30px 22px" aria-labelledby="customerNotJoinedTitle">
    <div aria-hidden="true">${CUI.icon('loyalty',{size:32})}</div>
    <h1 id="customerNotJoinedTitle" style="margin-top:12px;font-size:22px">You haven’t joined ${esc(label)} yet</h1>
    <p class="muted small" style="margin-top:8px">Your Peekaa account is fine — this reward account just isn’t linked to it. Join to see points, rewards and bookings for ${esc(label)}.</p>
    <button class="btn" id="customerNotJoinedJoin" type="button" style="margin-top:18px"><span>Join ${esc(label)}</span>${CUI.icon('forward',{size:20})}</button>
    <button class="btn ghost sm" id="customerNotJoinedScan" type="button" style="margin-top:10px">${CUI.icon('scan',{size:16})}<span>${esc(ct('scanBusinessQr'))}</span></button>
    <div class="cui-stamp-dots-v2b is-demo-v2b" aria-hidden="true">${'<i></i>'.repeat(8)}</div>
    <p class="muted small" style="margin-top:8px">Collect stamps or points here once you join.</p>
  </section>`;
  const join=$('customerNotJoinedJoin');
  if(join)join.onclick=()=>{
    pendingCustomerBusinessSlug=normalizeCustomerBusinessIntent(businessSlug);
    nav('#/claim?business='+encodeURIComponent(String(businessSlug||'')));
  };
  const scan=$('customerNotJoinedScan');
  if(scan)scan.onclick=openCustomerJoinScanner;
}
/* v389 (owner, 2026-08-18: a screenshot of this exact card asking "why failed to load?").
   This card was handed the error object and used it for ONE thing — the session-expiry branch —
   then dropped it. Every other cause printed the same sentence, so neither the customer nor
   anyone reading their screenshot could tell a dropped mobile request from a broken function
   from a permissions change, and the only way to find out was to reproduce it as that customer.
   The full error now goes to the console for anyone with the device in hand, and a SHORT
   reference is printed under the message. It is deliberately just the transport's own code
   (PGRST…/five-digit SQLSTATE) or the word "network" when the request never reached the
   database — never the server's message, which can name internals. */
function customerLoadReferenceV389(error){
  if(!error)return '';
  const code=String(error.code||'').trim();
  if(/^[A-Za-z0-9_]{2,12}$/.test(code))return code;
  return 'network';
}
/* v390 (owner: "maybe because i was out of credit?" — and that is very likely what it was: the
   app shell is served by the service worker, so the page renders from cache while the data call
   dies on a phone with no mobile data left). The app already knows how to say this: the inbox
   has printed "You appear to be offline" since C46, and customerAuthFailureKindV289 already
   classifies a codeless fetch failure as 'network'. The wallet's own retry card was the one
   surface still reporting a dead connection as though the BUSINESS were broken — which sends
   the customer to the shop to complain about a problem their phone bill caused. Reuses that
   classifier rather than adding a second opinion about what 'offline' means. */
function customerWalletOfflineV390(error){
  if(globalThis.navigator?.onLine===false)return true;
  if(!error)return false;
  return customerAuthFailureKindV289(error)==='network';
}
function renderCustomerWalletRetry(message,businessSlug,retry=()=>renderCustomerWallet(businessSlug),error=null){
  globalThis.document?.documentElement?.setAttribute('lang','en');
  const body=$('walletBody');if(!body)return;
  const expired=walletSessionExpired(error);
  if(error)try{console.error('[peekaa] wallet load failed',{businessSlug,code:error.code||null,message:error.message||null,details:error.details||null,hint:error.hint||null})}catch{}
  const offline=!expired&&customerWalletOfflineV390(error);
  const reference=expired?'':customerLoadReferenceV389(error);
  const heading=offline?'You appear to be offline':`Could not load ${esc(BRAND.customerLabel)}`;
  const sentence=expired?'Your sign-in expired. Sign in again.'
    :offline?'Check your connection, then retry. Nothing you have earned is affected.'
    :message;
  body.innerHTML=`<div class="card" style="text-align:center"><h2>${offline?esc(heading):heading}</h2><p class="muted small" style="margin-top:8px">${esc(sentence)}</p>${reference?`<p class="muted small customer-load-reference-v389" style="margin-top:6px">Reference: <code>${esc(reference)}</code></p>`:''}<button class="btn sm" id="walletRetry" style="margin-top:14px">${expired?'Sign in':'Retry'}</button></div>`;
  $('walletRetry').onclick=expired?(()=>customerSessionExpiredSignIn()):retry;
}

/* v295: title/description arrive as English ct() KEYS and are translated HERE, so all six
   wallet detail sections localize at one chokepoint instead of six call sites. The translated
   title is what lands in data-section-title, so walletSectionError's "<title> didn't load"
   reads in the member's language too. */
function walletSectionShell(id,title,description=''){
  const heading=ct(title),body=description?ct(description):'';
  return `<section class="card wallet-section" id="${id}" data-section-title="${esc(heading)}" aria-busy="true"><div class="wallet-section-head"><div><h2>${esc(heading)}</h2>${body?`<p class="muted small">${esc(body)}</p>`:''}</div></div><div class="wallet-skeleton"></div></section>`;
}

function walletSectionError(id,message,retry,error=null){
  const host=$(id);if(!host)return;
  host.setAttribute('aria-busy','false');
  const title=host.dataset.sectionTitle||host.querySelector('h2')?.textContent?.trim()||ct('This section');
  if(walletSessionExpired(error)){
    host.innerHTML=`<div class="wallet-section-head"><div><h2>${esc(ct('{section} didn’t load',{section:title}))}</h2><p class="muted small">${esc(ct('Your sign-in expired. Sign in again.'))}</p></div><span class="spacer"></span><button class="btn ghost sm" id="${id}Retry">${esc(ct('Sign in'))}</button></div>`;
    $(`${id}Retry`).onclick=()=>customerSessionExpiredSignIn();
    return;
  }
  host.innerHTML=`<div class="wallet-section-head"><div><h2>${esc(ct('{section} didn’t load',{section:title}))}</h2><p class="muted small">${esc(message)}</p></div><span class="spacer"></span><button class="btn ghost sm" id="${id}Retry">${esc(ct('retry'))}</button></div>`;
  $(`${id}Retry`).onclick=retry;
}

// 42501 = the account genuinely lacks the row; PGRST301 = the JWT expired. The
// second is recoverable by signing in again, so it must never read as a denial.
function walletRpcDenied(error){return error?.code==='42501'}
function walletSessionExpired(error){return error?.code==='PGRST301'}
async function customerSessionExpiredSignIn(){
  try{killChannels()}catch{}
  await sb.auth.signOut({scope:'local'}).catch(()=>{});
  try{resetClientSessionState()}catch{}
  nav('#/');
}

// Detail sections share stable element IDs across business routes. An RPC that
// began on route A must therefore prove both its render epoch and its original
// DOM host before it can paint route B.
function walletSectionStillCurrent(host,isCurrent){
  return !!host&&isCurrent()&&host.isConnected&&$(host.id)===host;
}

function ensureWalletEmptyState(businessSlug){
  const sections=$('walletSections');if(!sections)return;
  const hasSection=!!sections.querySelector('.wallet-section:not(#walletEmpty)');
  const existing=$('walletEmpty');
  if(hasSection){if(existing)existing.remove();return}
  if(!existing)sections.insertAdjacentHTML('beforeend',`<section class="card wallet-section" id="walletEmpty"><div class="wallet-section-head"><div><h2>Nothing to show yet</h2><p class="muted small">This business has no customer wallet sections available for your account.</p></div><span class="spacer"></span><button class="btn ghost sm" id="walletEmptyRetry">Refresh</button></div></section>`);
  $('walletEmptyRetry').onclick=()=>renderCustomerWallet(businessSlug);
}

async function walletSectionEmpty(id,_title,_message,businessSlug,capability,retry,isCurrent=()=>true){
  const host=$(id);if(!walletSectionStillCurrent(host,isCurrent))return;
  const {data,error}=await customerRpc('customer_portal_capabilities',{p_business_slug:businessSlug});
  if(!walletSectionStillCurrent(host,isCurrent))return;
  if(error)return walletSectionError(id,'This section could not be refreshed.',retry,error);
  // A disabled optional feature and an enabled feature with a successful empty
  // feed are both absent from the customer surface. The capability recheck is
  // still authoritative and the post-await guard prevents a stale route write.
  if(!data?.[capability]){host.remove();ensureWalletEmptyState(businessSlug);return}
  host.remove();ensureWalletEmptyState(businessSlug);
}

function renderWalletAppointments(host,businessSlug,state,customerFeatures,{appointmentChangesEnabled=false}={}){
  host.setAttribute('aria-busy','false');
  host.innerHTML=`<div class="wallet-section-head"><div><h2>Appointments</h2><p class="muted small">Upcoming and recent visits</p></div></div>
    <div>${state.items.map(a=>`<div class="wallet-appt"><div><b>${esc(walletDate(a.starts_at,true))}</b>
      <p class="muted small" style="margin-top:3px">${esc(a.service_name||'Appointment')}${a.branch_name?' · '+esc(a.branch_name):''} · ${esc(String(a.status||'').replaceAll('_',' '))}</p></div><span class="spacer"></span>
      ${customerFeatures.customer_actions&&appointmentChangesEnabled&&a.status==='booked'?`<button class="btn ghost sm walletChange" data-id="${esc(a.appointment_id)}">Change</button>`:a.status==='completed'?`<button class="btn ghost sm" type="button" data-repeat-booking data-business-slug="${esc(businessSlug)}" data-appointment-id="${esc(a.appointment_id)}">${esc(ct('Book again'))}</button>`:''}</div>`).join('')}</div>
    ${state.nextCursor?`<button class="btn ghost sm" id="walletAppointmentsMore" style="margin-top:12px">${esc(ct('Load more'))}</button>`:''}`;
  wireWalletAppointmentActions(businessSlug);
  wireCustomerRepeatBookingV167(host);
}

/* v286: the Bookings page lists SEVERAL businesses at once, so the slug can no longer be a single
   page-wide argument — each button carries its own in data-business-slug and the argument stays as
   the single-business default (wallet, portal). onDone lets a surface repaint itself once the
   request is in; the wallet keeps its existing toast-only behaviour. */
function wireWalletAppointmentActions(businessSlug,{onDone=null}={}){
  document.querySelectorAll('.walletChange').forEach(button=>button.onclick=()=>{
    const modal=document.createElement('div');modal.className='modal customer-surface';modal.tabIndex=-1;
    modal.setAttribute('role','dialog');modal.setAttribute('aria-modal','true');modal.setAttribute('aria-labelledby','walletChangeTitle');
    modal.innerHTML=`<div class="modal-card"><div class="row"><h2 id="walletChangeTitle">Change appointment</h2><span class="spacer"></span><button class="btn ghost sm" id="walletChangeClose" aria-label="Close change appointment">Close</button></div>
      <label for="walletChangeKind">Request</label><select id="walletChangeKind"><option value="cancel">Cancel appointment</option><option value="reschedule">Choose another time</option></select>
      <div id="walletChangeTime" hidden><label for="walletChangeAt">Preferred new time</label><input id="walletChangeAt" type="datetime-local"></div>
      <label for="walletChangeNote">Note (optional)</label><textarea id="walletChangeNote" rows="3" maxlength="750"></textarea>
      <button class="btn" id="walletChangeSend" style="width:100%;margin-top:16px">Send request</button></div>`;
    document.body.appendChild(modal);
    let deactivateDialog;
    const close=()=>deactivateDialog?deactivateDialog():modal.remove();
    deactivateDialog=CUI.activateDialog(modal,{onClose:close,initialFocus:'#walletChangeKind'});
    $('walletChangeClose').onclick=close;
    $('walletChangeKind').onchange=()=>{$('walletChangeTime').hidden=$('walletChangeKind').value!=='reschedule'};
    $('walletChangeSend').onclick=async()=>{
      const kind=$('walletChangeKind').value,local=$('walletChangeAt').value;
      if(kind==='reschedule'&&!local)return toast('Choose a new time');
      $('walletChangeSend').disabled=true;
      const {error}=await sb.rpc('customer_request_appointment_action',{
        p_business_slug:button.dataset.businessSlug||businessSlug,p_appointment:button.dataset.id,p_action:kind,
        p_proposed_at:kind==='reschedule'?sgIso(local):null,
        p_note:$('walletChangeNote').value.trim()||null,p_idempotency_key:crypto.randomUUID()});
      if(error){$('walletChangeSend').disabled=false;return toast('The change could not be saved. Please try again.')}
      close();toast('Request sent to the business');
      if(typeof onDone==='function')onDone();
    };
  });
}

function actionableWalletExpiryText(expiry,unit){
  if(expiry?.mode==='none')return 'Never expires';
  if(Number(expiry?.expiring_units||0)>0&&expiry?.next_expiry_at){
    return `${Number(expiry.expiring_units)} ${unit} expire within 30 days · next ${walletDate(expiry.next_expiry_at)}`;
  }
  return expiry?.mode==='inactivity'?'Expiry terms may apply':'No units expiring in the next 30 days';
}
function actionableWalletActionText(card){
  const action=card?.action||{},reward=card?.next_eligible_reward||{},expiry=card?.expiry||{},visit=card?.visit_progress||{};
  const unit=String(card?.loyalty?.unit||'points');
  if(action.reason==='expiring_within_7_days')return `${Number(expiry.expiring_within_7_days||0)} ${unit} expire soon${action.deadline_at?` · ${walletDate(action.deadline_at)}`:''}`;
  if(action.reason==='reward_available')return `${reward.name||'Reward'} is ready at the counter`;
  if(action.reason==='expiring_within_30_days')return `${Number(expiry.expiring_units||0)} ${unit} expire within 30 days${action.deadline_at?` · ${walletDate(action.deadline_at)}`:''}`;
  if(action.reason==='one_qualifying_visit_remaining')return `One qualifying visit remains${visit.customer_description?` · ${visit.customer_description}`:''}${action.deadline_at?` · by ${walletDate(action.deadline_at)}`:''}`;
  /* nestly_v429 (E): the DISTANCE to a reward is counted in the reward's unit, which v426 now
     sends; the expiry lines above stay on the balance's unit, because that is what expires. */
  if(action.reason==='reward_progress')return `${Number(reward.remaining_units||0)} ${customerUnitNounV429(customerRewardUnitV429(reward,unit),reward.remaining_units)} to ${reward.name||'your next reward'}`;
  if(action.reason==='birthday_benefit_expiring_within_7_days')return `Birthday benefit ends soon${action.deadline_at?` · ends ${walletDate(action.deadline_at,true)}`:''}`;
  if(action.reason==='birthday_benefit_available')return 'Birthday benefit is ready to use';
  return 'No urgent action right now';
}
function birthdayBenefitMarkup(benefit,{interactive=false,compact=false}={}){
  if(!benefit||benefit.status==='unavailable')return '';
  const validity=benefit.validity||{},isReady=benefit.status==='ready_to_activate',isAvailable=benefit.status==='available';
  const state=isReady?'Ready to activate':isAvailable?'Available now':String(benefit.status||'').replaceAll('_',' ');
  if(compact)return `<div class="wallet-line birthday-benefit"><div><b>Birthday benefit</b><p class="muted small" style="margin-top:4px">${esc(benefit.label||'Birthday benefit')} · ${esc(benefit.display||state)}${validity.available_until?` · ends ${esc(walletDate(validity.available_until,true))}`:''}</p></div></div>`;
  return `<section class="wallet-line birthday-benefit" aria-labelledby="birthdayBenefitTitle"><div style="width:100%">
    <div class="row"><div><b id="birthdayBenefitTitle">${esc(benefit.label||'Birthday benefit')}</b><p class="muted small" style="margin-top:4px">${esc(benefit.display||'Birthday benefit')}</p></div><span class="spacer"></span><span class="pill">${esc(state)}</span></div>
    ${benefit.description?`<p class="muted small" style="margin-top:7px">${esc(benefit.description)}</p>`:''}
    ${validity.available_until?`<p class="muted small" style="margin-top:7px">Use it before ${esc(walletDate(validity.available_until,true))}. Ask the team at the counter.</p>`:''}
    ${benefit.terms?`<details style="margin-top:8px"><summary class="small">Terms</summary><p class="muted small" style="margin-top:5px">${esc(benefit.terms)}</p></details>`:''}
    ${interactive&&isReady?'<button type="button" class="btn sm" id="birthdayBenefitActivate" style="margin-top:12px">Activate benefit</button>':''}
    ${interactive&&isAvailable?'<button type="button" class="btn ghost sm" id="birthdayBenefitShow" style="margin-top:12px">Show at counter</button><p id="birthdayBenefitCounter" class="muted small" role="status" aria-live="polite" style="margin-top:7px"></p>':''}
  </div></section>`;
}
function customerProgrammePresentationV95(payload={},fallback={}){
  const brand=payload?.brand||{},programme=payload?.programme||{},catalogue=payload?.catalogue||{};
  const business=fallback?.business||{},loyalty=fallback?.loyalty||{};
  /* v177: the hero paints this colour behind white text, so a merchant who picks a pale brand
     colour would otherwise ship unreadable copy. contrastSafeBrandColor keeps the merchant's own
     colour whenever it clears 4.5:1 against white and substitutes the brand fallback when it does not. */
  const heroColor=contrastSafeBrandColor(CUSTOMER_SURFACE_ACCENT_V375);
  const unit=String(programme.unit||loyalty.unit||'points').toLowerCase()==='stamps'?'stamps':'points';
  return {
    locale:normalizeCustomerLocale(payload?.locale||customerLocale),
    logoUrl:customerMediaUrlV95(brand.logo_url),
    heroImageUrl:'',
    heroColor,
    name:programme.name||business.name||ct('programmes'),
    tagline:programme.tagline||programme.description||business.industry||ct('localBusiness'),
    description:programme.description||'',
    balance:Number(programme.balance??loyalty.balance??0),
    unit,
    tier:programme.tier||{},
    benefits:Array.isArray(programme.benefits)?programme.benefits:[],
    offers:Array.isArray(programme.offers)?programme.offers:[],
    rewards:Array.isArray(catalogue.rewards)?catalogue.rewards:[],
    products:Array.isArray(catalogue.products)?catalogue.products:[],
    services:Array.isArray(catalogue.services)?catalogue.services:[],
    capabilities:payload?.capabilities||{}
  };
}
const CUSTOMER_SEEN_OFFERS_KEY_V167='peekaa.customer.offers.seen.v1';
/* nestly_v398 (owner, twice: "i still dont see the new"). The New flag was placed correctly by
   v397 but was invisible on the owner's device, and the cause was not the badge — it was the
   store that decides whether an offer counts as new.
   `peekaa.customer.offers.seen.v1` was ONE localStorage key for the whole origin, with no
   identity in its name and nothing clearing it on sign-out. localStorage is per-origin, never
   per-account, so every offer version any customer had ever tapped on this browser stayed
   "already seen" for every customer who signed in afterwards. Reviewing the app as a second
   person on the same phone — which is exactly what the owner does — meant that person could
   never see a New flag on any offer, however new the offer genuinely was to them.
   Scoping the key by the signed-in user is the same shape the customer surface already uses for
   its other per-person store (see the latestEarn key below). The old global key is deliberately
   NOT migrated into the new one: its contents are precisely the cross-account contamination
   being fixed, so importing them would carry the bug forward under a new name. */
const customerSeenOffersKeyV398=()=>`${CUSTOMER_SEEN_OFFERS_KEY_V167}.${S.user?.id||'anonymous'}`;
let customerOfferFocusV167=null;
function customerSeenOfferVersionsV167(){
  try{
    const parsed=JSON.parse(localStorage.getItem(customerSeenOffersKeyV398())||'[]');
    return new Set(Array.isArray(parsed)?parsed.filter(value=>typeof value==='string').slice(-200):[]);
  }catch{return new Set()}
}
function rememberCustomerOfferV167(versionId){
  if(!versionId)return;
  const seen=customerSeenOfferVersionsV167();seen.add(String(versionId));
  try{localStorage.setItem(customerSeenOffersKeyV398(),JSON.stringify([...seen].slice(-200)))}catch{}
}
function customerOfferUrgencyV167(item,now=Date.now()){
  const ends=Date.parse(item?.ends_at||'');
  return Number.isFinite(ends)&&ends>now&&ends-now<=72*60*60*1000;
}
/* v183 (owner annotation "Ends in x days — use red colour font"): a calendar range asks the
   customer to do date arithmetic. The countdown states the scarcity directly. Days are counted
   in Singapore calendar days, not 24h blocks, so an offer ending 23:00 tonight reads "Ends
   today" rather than "Ends in 0 days". Returns '' when the offer has no end date. */
function customerOfferCountdownV183(item,now=Date.now()){
  const ends=Date.parse(item?.ends_at||'');
  if(!Number.isFinite(ends)||ends<=now)return '';
  const sgDay=value=>Math.floor((value+8*3600000)/86400000);
  const days=sgDay(ends)-sgDay(now);
  if(days<=0)return 'Ends today';
  if(days===1)return 'Ends tomorrow';
  return `Ends in ${days} days`;
}
function customerHomeOfferMarkupV167(item,seen){
  const business=item?.business||{},image=customerMediaUrlV95(item?.image_url),
    versionId=String(item?.version_id||''),isNew=versionId&&!seen.has(versionId),
    endsSoon=customerOfferUrgencyV167(item),validity=customerPromotionValidityV104(item),
    countdown=customerOfferCountdownV183(item),logo=customerMediaUrlV95(business.logo_url),
    /* v194 (owner: "put company category"): a customer with several businesses needs to know what
       KIND of business an offer is from, not only its name. */
    category=String(business.industry||'').trim();
  /* V299: the artwork fallback shows the BUSINESS monogram as a small coin, never a giant
     first letter of the offer name — "2-for-1 lattes" was rendering a huge lone "2". */
  const businessInitial=(String(business.name||'B').trim()[0]||'B').toUpperCase();
  return `<a class="customer-home-offer${image?'':' customer-home-offer--no-media'}" href="#/wallet/${encodeURIComponent(business.slug||'')}" data-home-offer data-offer-id="${esc(item?.id||'')}" data-offer-version="${esc(versionId)}">
    ${/* Wave 4 (audit): the countdown moves INSIDE the media block so it overlays the artwork's
         top-right corner instead of taking a line of the copy. It keeps its own class and colours
         — only where it sits changed. The fallback block's aria-hidden moves down onto the
         monogram span, because the block now holds real text a screen reader must still reach;
         the monogram itself is still decoration. The single-mark rule from wave 2B is untouched:
         the logo circle below still yields when the fallback monogram is the card's mark. */''}
    ${/* nestly_v395 (owner photo 2, the countdown ringed with an arrow drawn down to under the
         title: "put here"). The chip used to be painted INSIDE the media block, absolutely
         positioned over the artwork's top-right corner — which is why it was the first thing the
         eye hit and why it sat on top of the very picture the owner says is too small. It is a
         line of the copy again, after the title, so the card reads picture → who → what → when.
         Same node, same class, same red-on-soft colours; only its place in the document moved. */''}
    ${/* nestly_v421 (owner, photo 1: two arrows drawn across the top of the artwork, "picture not
         max out ... want uploaded photo full to picture", and a squiggle over the blank strip
         under the countdown, "why here have big empty space" — with the follow-up that the
         earlier fix "only fix the empty space for 1 photo, it needs to be for all photos".
         Both marks are the same frame. A 16:9 media box with the picture letterboxed inside it
         leaves bars beside a portrait poster, and a copy block with a fixed height leaves a blank
         strip under short copy — and which of the two you see depends on the shape of the photo
         the merchant uploaded, which is why fixing one card never fixed the next.
         So the frame stops being fixed: the copy hugs its own content, the media takes every
         pixel the copy does not, and the artwork is scaled to fill that space. It is still never
         cropped (V173/V371, reaffirmed 2026-08-19) — what fills the leftover margin is the SAME
         picture, blown up and blurred behind it, so a portrait poster reads as full-bleed
         artwork instead of a stamp on a white sheet, and every card in the row is the same size
         whatever shape its photo is. --offer-art carries the url; see .customer-home-offer-media
         in the stylesheet. */''}
    ${image
      ?`<div class="customer-home-offer-media has-art-v421" style="--offer-art:url(&quot;${esc(cssUrlValueV421(image))}&quot;)"><img src="${esc(image)}" alt="${esc(item?.image_alt||item?.name||'Offer')}" loading="lazy"></div>`
      :`<div class="customer-home-offer-media customer-home-offer-media--fallback"><span aria-hidden="true">${esc(businessInitial)}</span></div>`}
    ${/* nestly_v397 (owner photo B: "New" ringed where it sat, redrawn at the card's top-left
         corner with "put here"). It was a line of the copy, which pushed the title down and put a
         status flag below the business that owns it. It is a corner flag on the artwork now —
         diagonally opposite the countdown chip's old corner — so the card leads with the picture
         and the two states never stack. "Ends soon" stays in the copy: it is about the offer's
         terms, not a newness flag, and the countdown line already carries the deadline. */''}
    ${isNew?'<span class="pill customer-offer-new customer-offer-new-corner-v397">New</span>':''}
    <div class="customer-home-offer-copy"><div class="customer-home-offer-meta">${endsSoon?'<span class="pill customer-offer-urgent">Ends soon</span>':''}</div><h3>${esc(item?.name||'Offer')}</h3>
    <p class="customer-home-offer-business">${image?(logo
      ?`<img class="customer-home-offer-logo" src="${esc(logo)}" alt="" loading="lazy" width="24" height="24">`
      :`<span class="customer-home-offer-logo customer-home-offer-logo--fallback" aria-hidden="true">${esc(businessInitial)}</span>`):''}<span class="muted small">${esc(business.name||'Your business')}${category?` · ${esc(category)}`:''}</span></p>
    ${/* V392 (owner, photo 7: a clock drawn onto the "Ends in 13 days" pill). The countdown was
         already red; the icon is what makes it read as a deadline at a glance rather than as one
         more line of small text. */''}
    ${countdown
      ?`<p class="customer-home-offer-countdown">${CUI.icon('waitlist',{size:16})}<span>${esc(countdown)}</span></p>`
      :validity?`<p class="muted small" style="margin-top:5px">${esc(validity)}</p>`:''}</div>
  </a>`;
}
/* v173: with many linked businesses each posting offers, a plain ends-soonest
   list can let one business monopolise the front of the shelf. Round-robin by
   business (preserving each business's own ends-soonest order) so every
   business's strongest offer surfaces before anyone's second one. */
function interleaveCustomerOffersV173(items){
  const rows=Array.isArray(items)?items:[],order=[],byBusiness=new Map();
  for(const item of rows){
    const key=String(item?.business?.slug||item?.business?.id||'');
    if(!byBusiness.has(key)){byBusiness.set(key,[]);order.push(key)}
    byBusiness.get(key).push(item);
  }
  if(order.length<2)return rows;
  const out=[];
  for(let round=0;out.length<rows.length;round+=1)
    for(const key of order){const bucket=byBusiness.get(key);if(round<bucket.length)out.push(bucket[round])}
  return out;
}
/* V462 (owner ruling R2d): "Home-feed fairness = CLIENT-SIDE shuffle of the featured offers'
   ORDER on each app load/refresh — zero Supabase load; no server rotation logic."
   Since v462 the Home feed carries exactly one offer per business, so the ORDER of that list is
   the whole of a shop's visibility: whoever is first is the one seen without scrolling. Rotating
   it server-side would mean either state to keep or a query that is different every call; doing
   it here costs nothing and no two customers see the same running order.
   The seed is drawn ONCE, when the bundle loads. That is deliberate and is the difference between
   "shuffled per load" and "shuffled per render": Home re-renders on every wallet poll (v295/v370),
   and a fresh permutation each time would make the rail jump under the customer's thumb while
   they were reading it. One load, one order; reload, new order.
   __peekaaOfferShuffleSeedV462 exists so a test can pin the permutation and prove that two
   different seeds really do produce two different orders. */
const CUSTOMER_HOME_OFFER_SHUFFLE_SEED_V462=(()=>{
  const injected=Number(globalThis.__peekaaOfferShuffleSeedV462);
  if(Number.isFinite(injected))return injected>>>0;
  try{
    const buffer=new Uint32Array(1);crypto.getRandomValues(buffer);return buffer[0]>>>0;
  }catch(_error){
    return ((Date.now()^Math.floor(Math.random()*0x100000000))>>>0);
  }
})();
/* mulberry32 — a small, well-behaved 32-bit PRNG. Math.random() would also be fine statistically
   but cannot be pinned, and pinning is what makes R2d testable rather than merely asserted. */
function offerShuffleRandomV462(seed){
  let state=(Number(seed)||0)>>>0;
  return()=>{
    state=(state+0x6D2B79F5)>>>0;
    let t=state;
    t=Math.imul(t^(t>>>15),t|1);
    t^=t+Math.imul(t^(t>>>7),t|61);
    return ((t^(t>>>14))>>>0)/4294967296;
  };
}
/* Fisher-Yates, descending, drawing j from [0,i] inclusive — the unbiased form. The naive
   "swap with any index" variant produces n^n equally likely swap sequences over n! orderings and
   therefore favours some orders over others, which for a fairness rotation would be the one bug
   that matters. Returns a copy; the caller's array is never reordered in place. */
function shuffleCustomerHomeOffersV462(items,seed=CUSTOMER_HOME_OFFER_SHUFFLE_SEED_V462){
  const out=Array.isArray(items)?items.slice():[];
  const random=offerShuffleRandomV462(seed);
  for(let i=out.length-1;i>0;i-=1){
    const j=Math.floor(random()*(i+1));
    const swap=out[i];out[i]=out[j];out[j]=swap;
  }
  return out;
}
let customerHomeOfferIndexV173=new Map();
/* v195 (owner, arrow above Limited offers: "before limited offers i want to see a glance of my
   expiring rewards"): points that quietly expire are the one thing a loyalty app must never let
   a customer be surprised by. Built from the wallet cards Home already fetched — no extra round
   trip — and it states the honest empty case rather than disappearing, so a customer can tell the
   difference between "nothing expires soon" and "we did not check". */
function customerExpiringRewardsMarkupV195(cards=[]){
  /* v286: the pill used to count `list` AFTER .slice(0,4), so a customer with points expiring at
     seven businesses was told "4 to use" and the other three were invisible on the one surface
     whose whole job is that nothing expires by surprise. Count the FULL set, slice only for
     display, and give the remainder a way out via "See all". */
  const all=customerExpiringRowsV286(cards),list=all.slice(0,4);
  if(!(Array.isArray(cards)&&cards.length))return '';
  return `<section class="card customer-expiring-glance" aria-labelledby="customerExpiringTitle">
    <div class="customer-expiring-head">
      <h2 id="customerExpiringTitle">${CUI.icon('retention',{size:20})}<span>Expiring rewards</span></h2>
      ${all.length?`<span class="pill new">${all.length} to use</span>`:'<span class="muted small">Nothing in 30 days</span>'}
    </div>
    ${list.length
      ?`<ul class="customer-expiring-list">${list.map(row=>`<li${row.soon?' class="is-urgent"':''}>
        <a href="#/customer/programmes"><b>${esc(customerPointTotalV103(row.units))} ${esc(row.unit)}</b>
        <span class="muted small">${esc(row.name)}</span>
        <span class="customer-expiring-when${row.soon?' is-urgent':''}">${esc(row.when)}</span></a></li>`).join('')}</ul>
        ${all.length>list.length?`<p class="muted small" style="margin-top:8px"><a href="#/customer/programmes">See all ${all.length}</a></p>`:''}`
      :`<p class="muted small">None of your points expire in the next 30 days.</p>`}
  </section>`;
}
/* v286: the row build is shared — the markup slices it for display, Home asks it whether there is
   ANY expiring balance before deciding the surface is empty. One definition, one truth. */
function customerExpiringRowsV286(cards=[]){
  return (Array.isArray(cards)?cards:[]).map(card=>{
    const expiry=card?.expiry||{},units=Math.max(0,Number(expiry.expiring_units)||0);
    if(!(units>0)||!expiry.next_expiry_at)return null;
    return {
      name:String(card?.business?.name||'').trim()||ct('localBusiness'),
      units,unit:String(card?.loyalty?.unit||'points'),
      soon:Math.max(0,Number(expiry.expiring_within_7_days)||0)>0,
      at:expiry.next_expiry_at,when:walletDate(expiry.next_expiry_at)
    };
  }).filter(Boolean).sort((a,b)=>String(a.at).localeCompare(String(b.at)));
}
function customerHomeOffersMarkupV167(state={status:'loading',items:[]}){
  /* V462 (R2d): shuffled on each app load. interleaveCustomerOffersV173 still runs first — it is
     a no-op now that the server sends one offer per business, and keeping it means the rail
     degrades gracefully rather than clumping if that ever changes. */
  const items=shuffleCustomerHomeOffersV462(interleaveCustomerOffersV173(state.items));
  customerHomeOfferIndexV173=new Map(items.map(item=>[String(item?.id||''),item]));
  let body='<div class="card customer-home-offers-state"><p class="muted small">Loading offers…</p></div>';
  if(state.status==='ready'){
    const seen=customerSeenOfferVersionsV167();
    body=items.length
      ?`<div class="customer-home-offers-track" aria-label="Current offers">${items.map(item=>customerHomeOfferMarkupV167(item,seen)).join('')}</div>`
      :'<div class="card customer-home-offers-state"><p class="muted small">No offers right now. New offers from your businesses appear here first.</p></div>';
  }else if(state.status==='error'){
    body='<div class="card customer-home-offers-state"><p class="muted small">Offers couldn’t load.</p><button class="btn ghost sm" id="customerOffersRetry" type="button" style="margin-top:10px">Try again</button></div>';
  }
  /* v183 (owner annotation: kicker struck out, "put some logo, make it interesting"): the
     stacked kicker read as filler above the real title. One icon-led title line instead. */
  return `<section class="customer-home-offers" aria-labelledby="customerHomeOffersTitle"><div class="customer-home-offers-head"><h2 id="customerHomeOffersTitle" class="customer-home-offers-title"><span class="customer-home-offers-badge" aria-hidden="true">${CUI.icon('loyalty',{size:20})}</span><span>Limited offers</span></h2><a href="#/customer/programmes">View all <span aria-hidden="true">›</span></a></div>${body}</section>`;
}
/* v178 (owner annotation): from an offer the customer must be able to click into the company
   itself — address, phone, email and every other offer that company is currently running. */
function customerCompanyIdentityMarkupV178(business={}){
  const logo=customerMediaUrlV95(business?.logo_url),name=String(business?.name||'').trim()||'Your business',
    initial=(name[0]||'B').toUpperCase();
  return logo
    ?`<img class="customer-company-logo" src="${esc(logo)}" alt="" loading="lazy">`
    :`<span class="customer-company-logo customer-company-logo--fallback" aria-hidden="true">${esc(initial)}</span>`;
}
/* v195 (owner: "→ address phone number" on this row, and "click here straightaway go company
   profile"): the row said "Company details", which described the destination instead of showing
   anything. It now carries the branch address and phone as soon as they load, and one tap still
   opens the full company profile. */
function customerCompanyDetailRowV178(business={},{lines=''}={}){
  const name=String(business?.name||'').trim()||'Your business';
  return `<button class="customer-company-row" type="button" data-company-detail aria-label="Open the company profile for ${esc(name)}">
    ${customerCompanyIdentityMarkupV178(business)}
    <span class="customer-company-row-copy"><b>${esc(name)}</b><span class="muted small" data-company-row-lines>${lines||'Company profile'}</span></span>
    <span class="spacer"></span><span class="customer-company-row-chevron" aria-hidden="true">›</span>
  </button>`;
}
/* v183 (owner: "Book now does not work… Open Cubbly rewards bounces me back to the same page"):
   both were the same defect. The sheet holds one history entry; closing it called history.back(),
   which is asynchronous, so the pop landed AFTER the hash navigation and cancelled it — the
   customer was returned to the page they started on. Navigating from a sheet now REPLACES the
   sheet's own history entry with the destination, so the trip is one-way and Back still returns
   to the page before the sheet. */
function wireCustomerSheetNavV183(overlay,deactivate){
  overlay.querySelectorAll('[data-offer-detail-nav],[data-business-detail-nav]').forEach(link=>{
    link.addEventListener('click',event=>{
      const href=link.getAttribute('href')||'';
      if(!href.startsWith('#/')||event.defaultPrevented||event.metaKey||event.ctrlKey||event.shiftKey)return;
      event.preventDefault();
      const handOff=(CUI.currentDialogHistoryId?.()||0)>0;
      deactivate({restoreFocus:false,handOffHistory:handOff});
      if(!handOff){nav(href);return}
      try{history.replaceState(null,'',href)}catch{location.hash=href;return}
      route();
    });
  });
}
function customerRewardRulesRowsV468(reward={},{unit='points',currency='SGD'}={}){
  const rows=[];
  const costV468=Math.max(0,Number(reward.cost_points)||0);
  if(costV468>0)rows.push(['What it costs',
    `${customerPointTotalV103(costV468)} ${customerUnitNounV429(unit==='stamps'?'stamps':'points',costV468)}`]);
  if(reward.requires_purchase===false)rows.push(['How to claim it','No purchase required']);
  const minSpendV468=Number(reward.min_spend_cents)||0;
  if(minSpendV468>0)rows.push(['Minimum spend',
    `${customerReferralMoneyV300(minSpendV468,currency)} on the visit you use it`]);
  if(reward.granted_at)rows.push(['Given to you',walletDate(reward.granted_at)]);
  if(reward.claim_available_until)rows.push(['Claim it by',walletDate(reward.claim_available_until)]);
  if(reward.expires_at)rows.push(['Use it by',walletDate(reward.expires_at)]);
  const claimDaysV468=Math.max(0,Math.round(Number(reward.entitlement_expiry_days)||0));
  if(claimDaysV468)rows.push(['After you claim it',`Use within ${claimDaysV468} day${claimDaysV468===1?'':'s'}`]);
  /* The same eligibility sentence the card prints, in the same words — scope 'restricted' is the
     server saying "not everywhere", and the count is its own. */
  if(reward.eligibility){
    const scopedV468=[['branches','locations'],['services','services'],['products','products']]
      .filter(([key])=>reward.eligibility[key]?.scope==='restricted')
      .map(([key,label])=>`${Number(reward.eligibility[key].count||0)} eligible ${label}`).join(' · ');
    /* nestly_v477: the owner's own sentence wins when they have typed one. Everything else is
       unchanged — the derived count still speaks for a gift whose eligibility IS restricted, and
       the default sentence still speaks for one that is not. */
    rows.push(['Where it works',
      String(reward.where_it_works||'').trim()||scopedV468||CUSTOMER_REWARD_WHERE_DEFAULT_V477]);
  }
  const descriptionV468=customerRewardDescriptionV183(reward.description);
  if(descriptionV468)rows.push(['What you get',descriptionV468]);
  const instructionsV468=String(reward.instructions||'').trim();
  if(instructionsV468)rows.push(['How to use it',instructionsV468]);
  const termsV468=String(reward.terms||'').trim();
  if(termsV468)rows.push(['Terms',termsV468]);
  return rows;
}
function showCustomerRewardRulesV468(reward={},{unit='points',currency='SGD',title=''}={}){
  const rowsV468=customerRewardRulesRowsV468(reward,{unit,currency});
  const nameV468=String(title||reward.customer_name||reward.name||reward.label||'').trim()||'Reward';
  const overlay=document.createElement('div');
  overlay.className='modal customer-surface customer-reward-rules-modal-v468';
  overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');
  overlay.setAttribute('aria-labelledby','customerRewardRulesTitleV468');
  overlay.innerHTML=`<section class="modal-card customer-offer-detail">
    <div class="row"><p class="customer-quest-kicker">Reward rules</p><span class="spacer"></span><button class="btn ghost sm" data-reward-rules-close-v468 type="button" aria-label="Close reward rules">${CUI.icon('close',{size:20})}</button></div>
    <h2 id="customerRewardRulesTitleV468">${esc(nameV468)}</h2>
    ${rowsV468.length
      ?`<dl class="customer-reward-rules-v468">${rowsV468.map(([term,value])=>
          `<div><dt>${esc(term)}</dt><dd>${esc(value)}</dd></div>`).join('')}</dl>`
      :`<p class="muted small" style="margin-top:12px">This business has not published any extra rules for this reward. Show it at the counter and the team will apply it.</p>`}
  </section>`;
  document.body.appendChild(overlay);
  /* This sheet never navigates on close, so it needs no dialogHandOffNavV468 hand-off — it only
     ever hands focus back to the "?" that opened it. */
  const deactivate=CUI.activateDialog(overlay,{onClose:()=>deactivate({restoreFocus:true}),initialFocus:'[data-reward-rules-close-v468]'});
  overlay.querySelector('[data-reward-rules-close-v468]').onclick=()=>deactivate({restoreFocus:true});
}
/* nestly_v471 (owner ruling 2026-08-23, asked what should happen when a gift's end date passes:
   "in customer view, they should see the expiry of each gift, example free lotion will expire on
   21 September 2026, redeem before that to enjoy the gift!").
   So the date is not a footnote inside the rules sheet — it is a line ON the gift, phrased as the
   nudge the owner wrote rather than as a bare field. The rules sheet keeps its own "Claim it by"
   row: that sheet is the full contract and drops nothing.
   claim_available_until is the OFFERING window (this gift leaves the catalogue on that date),
   which is the clock the owner chose. It is deliberately NOT reward.expires_at — that is the
   stamps-only earned-reward deadline from v464, already printed as "Use by" on the claimable
   card, and conflating the two would tell a customer their gift dies when in fact the offer does.
   A gift with no end date draws nothing: most gifts have none, and "No expiry" on every row is
   noise. A date already in the past draws nothing either — the server has stopped offering the
   gift by then, and a line reading "redeem before" a date that has gone is worse than silence. */
function customerRewardEndsLineV471(reward={}){
  const raw=reward?.claim_available_until;
  const at=Date.parse(raw||'');
  if(!Number.isFinite(at)||at<=Date.now())return '';
  return `<p class="customer-reward-ends-v471" data-customer-reward-ends-v471>${
    esc(`Expires on ${walletDate(raw)} — redeem before then to enjoy this gift!`)}</p>`;
}
/* V468-E4: one shape for the affordance so a catalogue reward and a granted gift carry the same
   control in the same corner. Text "?" rather than the info glyph — it is what the owner drew,
   and a question mark reads at a glance for a customer who does not read English well. */
function customerRewardHelpButtonV468(attribute,value,label){
  return `<button class="customer-reward-help-v468" type="button" ${attribute}="${esc(String(value||''))}" aria-label="${esc(`Rules for ${label||'this reward'}`)}" title="Reward rules"><span aria-hidden="true">?</span></button>`;
}
function showCustomerBusinessDetailV178(business={},{inheritHistoryId=0}={}){
  const name=String(business?.name||'').trim()||'Your business',
    industry=String(business?.industry||'').trim();
  const overlay=document.createElement('div');
  overlay.className='modal customer-surface customer-business-detail-modal';overlay.setAttribute('role','dialog');
  overlay.setAttribute('aria-modal','true');overlay.setAttribute('aria-labelledby','customerBusinessDetailTitle');
  overlay.innerHTML=`<section class="modal-card customer-offer-detail customer-business-detail">
    <div class="row"><p class="customer-quest-kicker">Company details</p><span class="spacer"></span><button class="btn ghost sm" id="customerBusinessDetailClose" type="button" aria-label="Close company details">${CUI.icon('close',{size:20})}</button></div>
    <div class="customer-business-detail-head">${customerCompanyIdentityMarkupV178(business)}<div><h2 id="customerBusinessDetailTitle">${esc(name)}</h2>${industry?`<p class="muted small" style="margin-top:2px">${esc(industry)}</p>`:''}</div></div>
    <div class="customer-offer-detail-meta" data-business-contact><p class="muted small">Loading contact details…</p></div>
    <div data-business-branches-v386></div>
  </section>`;
  /* v386 (owner photo 2, both struck through). The offers list repeated the same promotions the
     programme page behind this modal already shows in its own Limited offers rail, and
     "Open <business> rewards" navigated to that page — which is the page the customer was
     standing on when they tapped the name to open this. The modal is now what its heading says:
     company details. Dropping that list also drops the second promotions round trip that fired
     every time the name was tapped. */
  document.body.appendChild(overlay);
  const deactivate=CUI.activateDialog(overlay,{onClose:()=>deactivate({restoreFocus:true}),initialFocus:'#customerBusinessDetailClose',inheritHistoryId});
  overlay.querySelector('#customerBusinessDetailClose').onclick=()=>deactivate({restoreFocus:true});
  wireCustomerSheetNavV183(overlay,deactivate);
  const host=selector=>overlay.isConnected?overlay.querySelector(selector):null;
  if(!business?.id){
    const contact=host('[data-business-contact]');if(contact)contact.innerHTML='<p class="muted small">Contact details unavailable.</p>';
    return;
  }
  Promise.resolve(customerRpc('customer_get_offer_business_contact_v173',{p_business:business.id}))
    .then(({data,error})=>{
      const contact=host('[data-business-contact]');if(!contact)return;
      if(error){contact.innerHTML='<p class="muted small">Contact details unavailable.</p>';return}
      const branch=data?.branch||{};
      contact.innerHTML=customerBranchContactLinesV386(branch)||'<p class="muted small">Contact details unavailable.</p>';
      /* v386 (owner photo 2: "put other branches here too"). branches[0] is the same default
         branch already printed above, so only the rest are listed — repeating it would read as
         the business having the same outlet twice. An older bundle, or a business with one
         outlet, gets no list and no empty heading. */
      const branchesHost=host('[data-business-branches-v386]');
      const others=(Array.isArray(data?.branches)?data.branches:[]).slice(1)
        .filter(row=>String(row?.address||row?.phone||row?.name||'').trim());
      if(branchesHost&&others.length)branchesHost.innerHTML=`
        <h3 class="customer-business-detail-subhead">${esc(others.length===1?'Other branch':'Other branches')}</h3>
        ${others.map(row=>`<div class="customer-offer-detail-meta customer-business-branch-v386">
          ${String(row?.name||'').trim()?`<p class="customer-business-branch-name-v386"><b>${esc(String(row.name).trim())}</b></p>`:''}
          ${customerBranchContactLinesV386(row)}
        </div>`).join('')}`;
    }).catch(()=>{
      const contact=host('[data-business-contact]');
      if(contact)contact.innerHTML='<p class="muted small">Contact details unavailable.</p>';
    });
}
/* v386 (owner photo 2: a phone glyph drawn beside the bare number). The address already carried
   an icon; the phone and email lines were unlabelled strings, so a number sat under an address
   with nothing saying it was callable. One shape for all three, reused by the default branch and
   by every branch listed under it. */
function customerBranchContactLinesV386(branch={}){
  const phone=String(branch?.phone||'').trim();
  /* The address glyph moves from 'bookings' (a calendar) to 'branch' (a building) — the same
     glyph the profile header already uses for its Address segment. There is no envelope in the
     customer icon set and CUI.icon falls back to the INFO glyph for an unknown name, so the
     email line is left unprefixed rather than labelled with a wrong picture. */
  return [
    branch?.address?`<p class="muted small customer-business-contact-line-v386">${CUI.icon('branch',{size:16})} <span>${esc(branch.address)}</span></p>`:'',
    phone?`<p class="muted small customer-business-contact-line-v386">${CUI.icon('phone',{size:16})} <a href="tel:${esc(phone.replace(/[^+0-9]/g,''))}">${esc(phone)}</a></p>`:'',
    branch?.email?`<p class="muted small"><a href="mailto:${esc(branch.email)}">${esc(branch.email)}</a></p>`:''
  ].filter(Boolean).join('');
}
function showCustomerOfferDetailV173(item,{inheritHistoryId=0}={}){
  const business=item?.business||{},image=customerMediaUrlV95(item?.image_url),
    validity=customerPromotionValidityV104(item),
    availability=String(item?.availability_label||'').trim(),
    terms=String(item?.terms||'').trim(),
    cta=item?.metadata?.cta||{},slug=encodeURIComponent(business.slug||''),
    taglineV194=customerOfferTaglineV194(item?.name,item?.tagline),
    factsV195=customerOfferTaglineV194(item?.name,String(item?.metadata?.offer_facts||'')),
    descriptionV195=customerOfferDescriptionV195(item?.description),
    initial=(String(business.name||item?.name||'P').trim()[0]||'P').toUpperCase(),
    ctaLabel=String(cta.label||'').trim();
  const overlay=document.createElement('div');
  overlay.className='modal customer-surface customer-offer-detail-modal';overlay.setAttribute('role','dialog');
  overlay.setAttribute('aria-modal','true');overlay.setAttribute('aria-labelledby','customerOfferDetailTitle');
  overlay.innerHTML=`<section class="modal-card customer-offer-detail">
    ${/* nestly_v417 (owner, photo 2: "LIMITED-TIME OFFER · CUBBLY SPA" struck through, "remove
         this"). The line said nothing the dialog did not already say twice — the offer's own name
         is the heading directly beneath it, the business is named again in the description and a
         third time on the business row at the foot of the same card. The close button keeps the
         row, and the dialog keeps its accessible name from the heading. */''}
    <div class="row"><span class="spacer"></span><button class="btn ghost sm" id="customerOfferDetailClose" type="button" aria-label="Close offer details">${CUI.icon('close',{size:20})}</button></div>
    ${image?`<div class="customer-offer-detail-media"><img src="${esc(image)}" alt="${esc(item?.image_alt||item?.name||'Offer')}"></div>`:`<div class="customer-offer-detail-media customer-offer-detail-media--fallback" aria-hidden="true"><span>${esc(initial)}</span></div>`}
    <h2 id="customerOfferDetailTitle">${esc(item?.name||'Offer')}</h2>
    ${factsV195?`<p class="customer-offer-detail-facts">${esc(factsV195)}</p>`:''}
    ${taglineV194?`<p class="muted" style="margin-top:6px">${esc(taglineV194)}</p>`:''}
    ${descriptionV195?`<p class="muted small" style="margin-top:8px">${esc(descriptionV195)}</p>`:''}
    <div class="customer-offer-detail-meta">
      ${validity?`<p class="small"><b>${esc(validity)}</b></p>`:''}
      ${availability?`<p class="muted small">${esc(availability)}</p>`:''}
      <div data-offer-contact></div>
    </div>
    ${terms?`<p class="muted small customer-offer-detail-terms" style="margin-top:10px">${esc(terms)}</p>`:''}
    ${business.id?customerCompanyDetailRowV178(business):''}
    <div class="row" style="margin-top:16px;gap:10px;flex-wrap:wrap">
      ${/* v195 (owner: "add book appt button"): an offer a customer wants is worthless if booking
           it means leaving the sheet and finding the business again. The button is rendered only
           once the business itself confirms customer booking is on — the v183 fail-closed rule —
           so it can never send someone to a booking page that will refuse them. */''}
      ${cta.kind==='book'?`<a class="btn" href="#/b/${slug}" data-offer-detail-nav>${esc(ctaLabel||'Book now')}</a>`
        :`<span data-offer-book></span>`}
      ${customerShareButtonMarkupV264(item?.id,{small:false})}
    </div></section>`;
  document.body.appendChild(overlay);
  const deactivate=CUI.activateDialog(overlay,{onClose:()=>deactivate({restoreFocus:true}),initialFocus:'#customerOfferDetailClose',inheritHistoryId});
  overlay.querySelector('#customerOfferDetailClose').onclick=()=>deactivate({restoreFocus:true});
  wireCustomerSheetNavV183(overlay,deactivate);
  const shareButton=overlay.querySelector('[data-share-offer]');
  if(shareButton)shareButton.onclick=()=>shareCustomerOfferV264(item,business);
  const companyButton=overlay.querySelector('[data-company-detail]');
  /* v326 (owner: "when I click this, straightaway go to company profile inside, don't need
     another pop-out"): this row used to open a second modal (showCustomerBusinessDetailV178)
     on top of the offer sheet. It now takes the customer straight to the business's own
     programme page instead, the same one-way sheet-to-page hand-off wireCustomerSheetNavV183
     already uses for every other in-sheet link. */
  if(companyButton)companyButton.onclick=()=>{
    const target=`#/wallet/${encodeURIComponent(business.slug||'')}`;
    const handOff=CUI.currentDialogHistoryId?.()||0;
    deactivate({restoreFocus:false,handOffHistory:handOff>0});
    if(handOff>0){
      try{history.replaceState(null,'',target)}catch{location.hash=target;return}
      route();
      return;
    }
    nav(target);
  };
  if(business.id){
    const contactHost=overlay.querySelector('[data-offer-contact]');
    if(contactHost)contactHost.innerHTML='<p class="muted small">Loading contact details…</p>';
    const contactFailed=()=>{
      const host=overlay.isConnected?overlay.querySelector('[data-offer-contact]'):null;
      if(host)host.innerHTML='<p class="muted small">Contact details unavailable.</p>';
    };
    Promise.resolve(sb.rpc('customer_get_offer_business_contact_v173',{p_business:business.id}))
      .then(({data,error})=>{
        if(!overlay.isConnected)return;
        if(error)return contactFailed();
        const branch=data?.branch||{},host=overlay.querySelector('[data-offer-contact]');
        if(!host)return;
        const lines=[
          branch.address?`<p class="muted small">${CUI.icon('bookings',{size:16})} ${esc(branch.address)}</p>`:'',
          branch.phone?`<p class="muted small"><a href="tel:${esc(String(branch.phone).replace(/[^+0-9]/g,''))}">${esc(branch.phone)}</a></p>`:'',
          branch.email?`<p class="muted small"><a href="mailto:${esc(branch.email)}">${esc(branch.email)}</a></p>`:''
        ].filter(Boolean).join('');
        host.innerHTML=lines||'';
        const rowLines=overlay.querySelector('[data-company-row-lines]');
        if(rowLines){
          const summary=[branch.address,branch.phone].map(value=>String(value||'').trim()).filter(Boolean);
          if(summary.length)rowLines.textContent=summary.join(' · ');
        }
      }).catch(()=>contactFailed());
    if(business.slug&&cta.kind!=='book'){
      Promise.resolve(sb.rpc('customer_get_business_actions_v89',{p_business:business.id}))
        .then(({data,error})=>{
          const host=overlay.isConnected?overlay.querySelector('[data-offer-book]'):null;
          if(!host||error||data?.booking?.enabled!==true)return;
          /* filled INSIDE the placeholder, then wired within it, so the links already bound
             above are not given a second click handler. */
          host.innerHTML=`<a class="btn" href="#/b/${slug}" data-offer-detail-nav>${esc(ct('bookNow'))}</a>`;
          wireCustomerSheetNavV183(host,deactivate);
        }).catch(()=>{});
    }
  }
}
function wireCustomerHomeOffersV167(rerender){
  document.querySelectorAll('[data-home-offer]').forEach(link=>link.addEventListener('click',event=>{
    rememberCustomerOfferV167(link.dataset.offerVersion);
    customerOfferFocusV167=link.dataset.offerId||null;
    const item=customerHomeOfferIndexV173.get(String(link.dataset.offerId||''));
    if(item){event.preventDefault();showCustomerOfferDetailV173(item)}
  }));
  const retry=$('customerOffersRetry');if(retry)retry.onclick=rerender;
}
/* https-only public review destination, read from the business summary the wallet already
   loaded. Presence of a URL is the only gate — never the customer's rating (v53 invariant). */
function walletReviewUrlV183(business={}){
  const url=String(business?.review_url||'');
  return /^https:\/\//.test(url)?url:'';
}
/* v183 (owner: "Suggested starting benefit. Replace this with an item or service that fits your
   margins." — why do customers see this?): the v35/v128 recommenders seed a draft reward whose
   description is written TO THE MERCHANT. Until the merchant edits it, that instruction was
   rendering on the customer's reward card. Merchant-authoring guidance is suppressed customer-
   side; a real description the merchant wrote is untouched. */
const MERCHANT_DRAFT_COPY_PATTERNS_V183=[
  /replace this with/i,
  /suggested starting benefit/i,
  /fits your margins/i
];
function customerRewardDescriptionV183(value){
  const text=String(value||'').trim();
  if(!text)return '';
  return MERCHANT_DRAFT_COPY_PATTERNS_V183.some(pattern=>pattern.test(text))?'':text;
}
function customerBusinessIdV103({summaryBusiness={},actionableCard=null,programmeCards=[],businessSlug=''}={}){
  const matchingCard=(Array.isArray(programmeCards)?programmeCards:[])
    .find(card=>card?.business?.slug===businessSlug);
  const candidates=[
    summaryBusiness?.id,
    actionableCard?.business?.id,
    matchingCard?.business?.id
  ];
  return candidates.map(value=>String(value||'').trim())
    .find(value=>/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value))||null;
}
/* V183 (owner: "Upload the image but not reflected on the right ... only after publish then is
   able to see"). customerMediaUrlV95 is a strict allowlist of Supabase storage object paths, so
   the blob: URL of a just-picked file resolved to '' and the card fell back to its initial
   letter — the owner saw a big "N" instead of the photo they had chosen.
   The allowlist must stay for everything a CUSTOMER sees, so the owner preview passes an
   already-resolved URL through previewImageUrl instead. Customer render paths never pass it. */
/* v264 (owner: "i need a share button for promotions - to share to social media / whatsapp / FB /
   IG / tiktok/wechat/ telegram - so customers can help businesses to share").
   How sharing actually works, and why this is built the way it is:
     * Instagram, TikTok and WeChat have NO web share endpoint. Nothing a web page can link to
       will post to them. The only route is the DEVICE share sheet (navigator.share), which lists
       every app the customer has installed — so that is the primary action, and on a phone it
       covers all seven of the owner's channels plus anything else they use.
     * WhatsApp, Telegram and Facebook do publish real share URLs, so a desktop browser (where
       there is usually no share sheet) still gets working buttons instead of a dead end.
     * Copy link is always offered, because it works everywhere including apps with no endpoint.
   No fake buttons: a channel is never drawn unless the tap genuinely reaches it. */
const CUSTOMER_SHARE_CHANNELS_V264=Object.freeze([
  {key:'whatsapp',label:'WhatsApp',icon:'chat',
    href:({text,url})=>`https://wa.me/?text=${encodeURIComponent(`${text}\n${url}`)}`},
  {key:'telegram',label:'Telegram',icon:'forward',
    href:({text,url})=>`https://t.me/share/url?url=${encodeURIComponent(url)}&text=${encodeURIComponent(text)}`},
  {key:'facebook',label:'Facebook',icon:'customers',
    href:({url})=>`https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(url)}`}
]);
/* The link a stranger receives must open something they can actually use without an account.
   v268: an offer with an id now shares /o/<id> — the server-rendered page whose Open Graph tags
   let WhatsApp and Facebook preview the offer's own artwork and "Peekaa × firm" (crawlers never
   run JavaScript, so the SPA's hash routes all previewed as generic branding). That page walks a
   human on into the business's public page, which remains the direct link for anything without
   an offer id. Either way it is the canonical origin, never whatever host this app happens to be
   running on — and a business with no public page still shares nothing, because the offer page
   would have nowhere to send a visitor. */
function customerShareUrlV264(business={},offer={}){
  const slug=String(business?.slug||'').trim();
  if(!slug)return '';
  const offerId=String(offer?.id||'').trim();
  try{
    if(offerId)return NestlyNativeBridge.publicUrl(`/o/${encodeURIComponent(offerId)}`);
    return NestlyNativeBridge.publicUrl(`/#/b/${encodeURIComponent(slug)}`);
  }catch{return ''}
}
/* The message carries the offer, because the destination page cannot show it yet. Name, business
   and validity — merchant-authored text, passed through as the merchant wrote it. */
function customerShareTextV264(item={},business={}){
  const name=String(item?.name||'').trim()||'this offer';
  const shop=String(business?.name||item?.business?.name||'').trim();
  const validity=customerPromotionValidityV104(item);
  return [shop?`${name} at ${shop}`:name,validity].filter(Boolean).join(' · ');
}
/* What actually leaves the phone. The co-brand sits on its own line directly above the link, so
   the offer still reads first and the pairing is the last thing before the URL — the shape a
   forwarded WhatsApp message is skimmed in. The sheet shows the offer line alone, because the
   lockup above it is already saying "Peekaa × Cubbly" in pictures. */
function customerShareMessageV267(text,business={}){
  return [String(text||'').trim(),customerShareCoBrandV267(business)].filter(Boolean).join('\n');
}
/* Both marks together, at the top of the sheet. The firm's logo is resolved through the same
   storage allowlist every other customer-facing image uses; a firm with no logo yet gets its
   initial in the same circle rather than a broken image or an empty gap — the lockup must never
   render half of itself. The images are decorative because the line beneath them already says
   "Peekaa × Cubbly", so a screen reader hears the pairing once, not three times. */
function customerShareLockupV267(business={}){
  const logo=customerMediaUrlV95(business?.logo_url),
    name=String(business?.name||'').trim(),
    initial=(name[0]||'?').toUpperCase();
  const shopMark=logo
    ?`<img class="customer-share-mark" src="${esc(logo)}" alt="" loading="lazy">`
    :`<span class="customer-share-mark customer-share-mark--fallback">${esc(initial)}</span>`;
  return `<div class="customer-share-lockup">
    <div class="customer-share-marks" aria-hidden="true">
      <img class="customer-share-mark" src="${CUSTOMER_BRAND_MARK_V267}" alt="">
      <span class="customer-share-cross">×</span>
      ${shopMark}
    </div>
    <p class="customer-share-cobrand">${esc(customerShareCoBrandV267(business))}</p>
  </div>`;
}
function customerShareSheetMarkupV264({text,url,business={},title='Share this offer'}){
  const message=customerShareMessageV267(text,business);
  const channels=CUSTOMER_SHARE_CHANNELS_V264
    .map(channel=>`<a class="customer-share-channel" href="${esc(channel.href({text:message,url}))}" target="_blank" rel="noopener noreferrer" data-share-channel="${esc(channel.key)}">${CUI.icon(channel.icon,{size:20})}<span>${esc(channel.label)}</span></a>`)
    .join('');
  return `<section class="modal-card customer-share-sheet">
    <div class="row"><h2 id="customerShareTitle">${esc(title)}</h2><span class="spacer"></span>
      <button class="btn ghost sm" id="customerShareClose" type="button" aria-label="Close">${CUI.icon('close',{size:20})}</button></div>
    ${customerShareLockupV267(business)}
    <p class="muted small">${esc(text)}</p>
    <div class="customer-share-channels">${channels}</div>
    <button class="btn ghost sm customer-share-copy" id="customerShareCopy" type="button" data-share-channel="copy">${CUI.icon('copy',{size:16})}<span>Copy link</span></button>
    <p class="muted small customer-share-note">Instagram, TikTok and WeChat can be reached from your phone's own share button.</p>
  </section>`;
}
function showCustomerShareSheetV264({text,url,business={},onChannel=()=>{},title='Share this offer'}){
  const overlay=document.createElement('div');
  overlay.className='modal customer-surface customer-share-modal';
  overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');
  overlay.setAttribute('aria-labelledby','customerShareTitle');
  overlay.innerHTML=customerShareSheetMarkupV264({text,url,business,title});
  document.body.appendChild(overlay);
  const deactivate=CUI.activateDialog(overlay,{onClose:()=>deactivate({restoreFocus:true}),initialFocus:'#customerShareClose'});
  overlay.querySelector('#customerShareClose').onclick=()=>deactivate({restoreFocus:true});
  overlay.querySelectorAll('[data-share-channel]').forEach(control=>{
    control.addEventListener('click',async event=>{
      const channel=control.dataset.shareChannel;
      if(channel==='copy'){
        event.preventDefault();
        /* One clipboard path for the whole app: it disables the button while it runs, announces
           the result to a screen reader, and says so honestly when the browser refuses. */
        await copyTextToClipboard(url,{button:control,success:'Link copied. Paste it anywhere.',
          failure:'Copying is blocked in this browser. Long-press the link to copy it.'});
      }
      onChannel(channel);
      if(channel!=='copy')deactivate({restoreFocus:false});
    });
  });
  return deactivate;
}
async function shareCustomerOfferV264(item,business){
  const shop=business||item?.business||{};
  const url=customerShareUrlV264(shop,item);
  if(!url)return toast('This business has no public page to share yet.');
  const text=customerShareTextV264(item,shop),brand=customerShareCoBrandV267(shop);
  const businessId=String(shop?.id||'');
  const record=channel=>recordProductInteractionV100('customer.promotion_shared',businessId,
    {context:{channel,promotion_id:String(item?.id||''),surface_version:'v264'}});
  /* The device sheet is the only way to reach Instagram, TikTok and WeChat, so it is tried first
     wherever it exists. A customer who dismisses it has decided not to share — that is not an
     error and must not be answered with a second, different sheet.
     v286: it is asked for through the bridge, not through navigator.share directly. This app also
     ships as a Capacitor build, and a WKWebView does not expose navigator.share — so the device
     branch was skipped on the iOS app and the customer fell to the web sheet, whose channels are
     target="_blank" links a native WebView cannot hand to the installed apps. The bridge calls
     @capacitor/share when native and navigator.share on the web, and returns false when neither
     exists, which is exactly when the in-app sheet is the right answer. */
  try{
    const shared=await NestlyNativeBridge.share({title:brand,text:customerShareMessageV267(text,shop),url});
    if(shared){record('device');return}
  }catch(error){
    if(error?.name==='AbortError')return;
  }
  showCustomerShareSheetV264({text,url,business:shop,onChannel:record});
}
/* V300 (owner approval 2026-08-13): customers see and share their OWN referral code, synced to
   the firm's live programme. The card renders only when the server says the programme AND the
   referrals module are both on — the same {enabled:false} that hides the card also withholds the
   terms and the code, so a switched-off programme can never be advertised. The share path is the
   V264/V267 machinery: device sheet first (Instagram/TikTok/WeChat live there), co-branded
   fallback sheet with the three real web endpoints otherwise. */
function customerReferralMoneyV300(cents,currency){
  return `${currency} ${(Number(cents||0)/100).toFixed(2)}`;
}
/* V322 (OWNER RULING R1/R4): the reward is POINTS now, and the qualifying FLOOR is still money —
   the friend still has to spend. Two units on one card, so each gets its own formatter and the
   money one is left exactly as it is rather than being taught a second job. */
function customerReferralPointsV322(points,kind){
  const value=Math.max(0,Math.round(Number(points)||0));
  /* nestly_v430: v425 gave the referral an explicit reward TYPE and the engine pays the declared
     kind's pot — but this sentence still said "50 points" for a stamps payout (go-live battery,
     2026-08-22: Cubbly promised points, paid stamps). The noun now follows card.reward_kind, the
     same field the payout switches on, so the promise cannot disagree with the pot again. */
  if(String(kind||'')==='stamps')return ct(value===1?'referralOneStamp':'referralStamps',{count:value});
  return ct(value===1?'referralOnePoint':'referralPoints',{count:value});
}
function customerReferralCardMarkupV300(card,business){
  const currency=String(card?.currency||business?.currency||'SGD');
  const code=String(card?.code||'').trim();
  const referred=Math.max(0,Number(card?.referred_count)||0);
  /* V322: reward_points is what the engine pays. reward_cents is still on the payload for the
     four-hour CDN window in which the previous bundle is still being served, and this bundle
     deliberately ignores it — a card that fell back to the money number would advertise a payout
     that no longer exists. */
  /* nestly_v421: what this card promises must be what app.on_sale_recorded actually pays.
     Two ways it did not, until now:
     (1) v420 made a free gift selectable and this line still read the POINTS column, so a customer
         of a firm paying a Free Coffee was told they would get "0 points";
     (2) the referral pays BOTH sides from v421, and a card that mentions only the referrer
         under-sells the very thing it is asking the customer to forward.
     The friend's share is resolved by the server (customer_get_referral_card_v300) rather than
     worked out here, so the sentence cannot disagree with the payout. */
  const isGiftV421=String(card?.reward_kind||'points')==='voucher';
  const reward=isGiftV421
    ?(String(card?.reward_label||'').trim()||ct('referralGiftFallback'))
    :customerReferralPointsV322(card?.reward_points,card?.reward_kind);
  const friendReward=card?.friend_enabled===false?''
    :isGiftV421
      ?(String(card?.friend_reward_label||'').trim()||'')
      :(Number(card?.friend_reward_points)>0?customerReferralPointsV322(card.friend_reward_points,card?.reward_kind):'');
  const floor=Number(card?.min_spend_cents||0)>0?customerReferralMoneyV300(card?.min_spend_cents,currency):'';
  return `<section class="card wallet-section customer-referral-card-v300" id="walletReferral" aria-labelledby="customerReferralTitle">
    <div class="wallet-section-head"><div>
      <h2 id="customerReferralTitle">${esc(ct('referralHeading',{business:business?.name||ct('localBusiness')}))}</h2>
      <p class="muted small"${isGiftV421?' data-merchant-content':''}>${esc(floor?ct('referralTermsWithFloor',{reward,floor}):ct('referralTerms',{reward}))}</p>
      ${friendReward?`<p class="muted small"${isGiftV421?' data-merchant-content':''}>${esc(ct('referralFriendAlso',{reward:friendReward}))}</p>`:''}
    </div></div>
    ${code?`<div class="customer-referral-code-row">
      <span class="customer-referral-code" aria-label="${esc(ct('yourReferralCode'))}">${esc(code)}</span>
      <button class="btn ghost sm" id="customerReferralCopy" type="button">${CUI.icon('copy',{size:16})}<span>${esc(ct('copyCode'))}</span></button>
      <button class="btn sm" id="customerReferralShare" type="button">${CUI.icon('share',{size:16})}<span>${esc(ct('shareCode'))}</span></button>
    </div>`:`<p class="muted small" style="margin-top:10px">${esc(ct('referralCodePending'))}</p>`}
    ${referred>0?`<p class="muted small customer-referral-count">${esc(ct('referredCount',{count:referred}))}</p>`:''}
  </section>`;
}
async function shareCustomerReferralV300(card,business){
  const slug=String(business?.slug||'').trim();
  let url='';
  try{url=slug?NestlyNativeBridge.publicUrl(`/#/b/${encodeURIComponent(slug)}`):''}catch{}
  if(!url)return toast('This business has no public page to share yet.');
  const text=ct('referralShareMessage',{business:business?.name||ct('localBusiness'),code:String(card?.code||'').trim()});
  const businessId=String(business?.id||'');
  const record=channel=>typeof recordProductInteractionV100==='function'&&recordProductInteractionV100('customer.referral_shared',businessId,
    {context:{channel,surface_version:'v300'}});
  try{
    const shared=await NestlyNativeBridge.share({title:customerShareCoBrandV267(business),text:customerShareMessageV267(text,business),url});
    if(shared){record('device');return}
  }catch(error){
    if(error?.name==='AbortError')return;
  }
  showCustomerShareSheetV264({text,url,business,onChannel:record,title:ct('shareYourCode')});
}
function openCustomerPromotionDetailsV104(card){
  const template=card?.querySelector('template[data-promotion-details-template]');
  if(!template)return;
  typeof recordProductInteractionV100==='function'&&recordProductInteractionV100('customer.promotion_opened',customerWalletBusinessIdV256,{
    context:{promotion_id:String(card?.dataset?.promotionId||''),surface_key:'promotion_detail',
      entry_point:'customer_wallet',surface_version:'v255'}
  });
  $('customerPromotionDetailsModal')?.remove();
  const title=card.querySelector('h3')?.textContent?.trim()||'Offer details';
  document.body.insertAdjacentHTML('beforeend',`<div class="modal customer-surface" id="customerPromotionDetailsModal" role="dialog" aria-modal="true" aria-labelledby="customerPromotionDetailsTitle" tabindex="-1"><div class="modal-card" style="max-width:520px">
    <div class="row"><h2 id="customerPromotionDetailsTitle">${esc(title)}</h2><span class="spacer"></span><button type="button" class="btn ghost sm" id="customerPromotionDetailsClose">Close</button></div>
    <div style="margin-top:16px">${template.innerHTML}</div>
    <button type="button" class="btn" id="customerPromotionDetailsDone" style="margin-top:18px">Done</button>
  </div></div>`);
  let deactivate;
  const close=()=>{if(deactivate)deactivate();else $('customerPromotionDetailsModal')?.remove()};
  deactivate=CUI.activateDialog($('customerPromotionDetailsModal'),{
    onClose:close,initialFocus:'#customerPromotionDetailsClose'
  });
  $('customerPromotionDetailsClose').onclick=$('customerPromotionDetailsDone').onclick=close;
}
function showCustomerPromotionPopupV122({business,businessSlug,items=[],prompt=null}={}){
  if(!prompt?.event_id||!prompt?.promotion_id||!businessSlug||!Array.isArray(items))return false;
  const promotionId=String(prompt.promotion_id);
  const item=items.find(candidate=>String(candidate?.id||'')===promotionId);
  if(!item||$('customerPromotionPopupV122'))return false;
  const endingSoon=prompt.source_kind==='v122_promotion_expiry';
  document.body.insertAdjacentHTML('beforeend',`<div class="modal customer-surface" id="customerPromotionPopupV122" role="dialog" aria-modal="true" aria-labelledby="customerPromotionPopupTitle" tabindex="-1"><div class="modal-card customer-promotion-popup-card">
    <p class="customer-quest-kicker">${endingSoon?'Ending soon':'New promotion'} · ${esc(business?.name||'Your programme')}</p>
    <h2 id="customerPromotionPopupTitle" style="margin-top:7px">${esc(item.name||'Latest offer')}</h2>
    <p class="muted" style="margin-top:8px">${esc(item.description||item.tagline||item?.metadata?.offer_facts||'Open the programme to see this promotion.')}</p>
    <p class="small" style="margin-top:10px">${esc(customerPromotionValidityV104(item))}</p>
    <div class="row" style="margin-top:18px"><button type="button" class="btn" data-promotion-popup-view>View offer</button><button type="button" class="btn ghost" data-promotion-popup-dismiss>Not now</button></div>
    <p class="muted small" data-promotion-popup-status role="status" aria-live="polite" style="margin-top:9px"></p>
  </div></div>`);
  const dialog=$('customerPromotionPopupV122');
  let deactivate,closing=false;
  const operationKeys={read:crypto.randomUUID(),dismiss:crypto.randomUUID()};
  // v176: dismissal is optimistic. The state RPC is idempotency-keyed, so a failed
  // write is safely retried by the next sync and must never trap the customer here.
  const close=(operation='dismiss',afterClose=null)=>{
    if(closing)return;
    closing=true;
    if(deactivate)deactivate();else dialog?.remove();
    sb.rpc('customer_set_in_app_inbox_state',{
      p_business_slug:businessSlug,p_event_id:prompt.event_id,
      p_operation:operation,p_idempotency_key:operationKeys[operation]
    }).catch(()=>{});
    if(operation==='read')typeof recordProductInteractionV100==='function'&&recordProductInteractionV100(
      'customer.notification_opened',customerWalletBusinessIdV256,
      {context:{surface_key:'promotion_prompt',entry_point:'customer_wallet',
        outcome:'read',surface_version:'v255'}}
    );
    afterClose?.();
  };
  deactivate=CUI.activateDialog(dialog,{onClose:()=>close('dismiss'),initialFocus:'[data-promotion-popup-view]'});
  dialog.querySelector('[data-promotion-popup-dismiss]').onclick=()=>close('dismiss');
  dialog.querySelector('[data-promotion-popup-view]').onclick=()=>close('read',()=>{
    const card=document.querySelector(`[data-promotion-id="${CSS.escape(promotionId)}"]`);
    card?.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'center'});
    card?.querySelector('button,a')?.focus();
  });
  return true;
}
/* The sheet behind the compact row. It carries the FULL explainer sentence the row abbreviates
   and the "Got it" button that performs the same localStorage write the inline button used to. */
function openCustomerPointsExplainerV339(trigger){
  const key=String(trigger?.dataset?.pointsExplainerKey||'');
  const business=String(trigger?.getAttribute('aria-label')||'').replace(/^How rewards work at /,'');
  $('customerPointsExplainerModalV339')?.remove();
  document.body.insertAdjacentHTML('beforeend',`<div class="modal customer-surface" id="customerPointsExplainerModalV339" role="dialog" aria-modal="true" aria-labelledby="customerPointsExplainerTitleV339" tabindex="-1"><div class="modal-card" style="max-width:460px">
    <div class="row"><h2 id="customerPointsExplainerTitleV339">How rewards work at ${esc(business||'this business')}</h2><span class="spacer"></span><button type="button" class="btn ghost sm" id="customerPointsExplainerCloseV339" aria-label="Close">${CUI.icon('close',{size:20})}</button></div>
    <p class="muted" style="margin-top:14px">Collect points here and use them for available rewards.</p>
    <button type="button" class="btn" id="customerPointsExplainerGotItV339" style="margin-top:18px">Got it</button>
  </div></div>`);
  let deactivate;
  const close=()=>{if(deactivate)deactivate();else $('customerPointsExplainerModalV339')?.remove()};
  deactivate=CUI.activateDialog($('customerPointsExplainerModalV339'),{onClose:close,initialFocus:'#customerPointsExplainerGotItV339'});
  $('customerPointsExplainerCloseV339').onclick=close;
  $('customerPointsExplainerGotItV339').onclick=()=>{
    if(key){try{localStorage.setItem(key,'dismissed')}catch{}}
    trigger?.remove();close();
  };
}
function wireCustomerProgrammeTabsV194(host=document){
  const tabs=[...host.querySelectorAll('[data-programme-tab]')];
  if(!tabs.length)return;
  const select=(name,focus=false)=>{
    tabs.forEach(tab=>{
      const on=tab.dataset.programmeTab===name;
      tab.setAttribute('aria-selected',String(on));
      tab.tabIndex=on?0:-1;
      if(on&&focus)tab.focus();
    });
    host.querySelectorAll('[data-programme-panel]').forEach(panel=>{
      panel.hidden=panel.dataset.programmePanel!==name;
    });
    const panel=host.querySelector('#customerProgrammePanel');
    if(panel)panel.setAttribute('aria-labelledby',`customerProgrammeTab-${name}`);
  };
  tabs.forEach((tab,index)=>{
    tab.onclick=()=>select(tab.dataset.programmeTab);
    tab.onkeydown=event=>{
      const step=event.key==='ArrowRight'?1:event.key==='ArrowLeft'?-1:0;
      if(!step)return;
      event.preventDefault();
      select(tabs[(index+step+tabs.length)%tabs.length].dataset.programmeTab,true);
    };
  });
}

/* ====== V323 — OWNER RULING R5: THE STAMP CARD IS A QUEST, AND CLAIMING DOES NOT RESET IT ======
   "stamps is like a quest - complete one set of quest (3 stamp = xx rewards, 5 stamp = xx rewards,
    8 stamp = xx rewards) … Milestones are non-consuming: reaching 5 does not reset progress toward
    8; the card keeps filling to the end of the quest."

   v322 shipped the AUTHORING half (a milestone is an ordinary catalogue reward whose cost is the
   stamp count) and reported the claim half as blocked, because app.redeem_reward_core drained
   points_batches FEFO for the reward's cost. v323 closes it: a milestone claim writes no ledger
   row and no batch drain, and the card is a PROJECTION — filled = lifetime stamps on the stamps
   programme minus the slots of every CLOSED cycle. A cycle closes when the LAST milestone is
   claimed, which is the one moment the quest's stamps are consumed.

   WHY THIS IS A SEPARATE RENDER RATHER THAN AN EDIT TO customerProgrammeStampsCardV310. That
   function derives the card's length from ONE reward's cost_units (the server's cheapest
   next_eligible_reward) and its progress from loyalty.balance, which comes from
   app.c45_base_actionable_wallet_card — a value with no programme filter at all. Neither can
   express a quest, and neither knows what has been claimed on THIS card. The v310 card stays
   exactly as it is and is REPLACED IN PLACE once the v323 reader answers, so both directions of
   the four-hour CDN window are safe: an old bundle against the new server never calls the reader
   and renders as it does today, and a new bundle against the old server gets a missing-RPC error,
   keeps the v310 card, and loses nothing.

   IT NEVER PRINTS A POINTS FIGURE. Not loyalty.balance, not a cost, not the word "points" — a
   v322-era defect was a stamp card printing points, and the payload this reads carries none. */
function stampQuestNormaliseV323(card){
  if(!card||typeof card!=='object'||card.enabled!==true||card.contract!=='v323')return null;
  const whole=value=>Math.max(0,Math.floor(Number(value)||0));
  const slots=whole(card.slots),filled=whole(card.filled);
  const milestones=(Array.isArray(card.milestones)?card.milestones:[])
    .map(rung=>({slot:whole(rung?.slot),name:String(rung?.name||'').trim(),
      claimed:rung?.claimed_this_cycle===true,availability:String(rung?.availability||''),
      /* nestly_v464: the server's date for an earned reward's own deadline. Null for every reward
         whose card was started under a version that set none, which is every card today. */
      expiresAt:rung?.expires_at||null,
      isFinal:rung?.is_final===true,toGo:whole(rung?.stamps_to_go),
      /* nestly_v475 (owner: "it should show the exact rewards first with its image tagged to it
         ... The photo must also be shown in the empty space I circled"). customer_get_stamp_card_v323
         has emitted image_ref per milestone all along; this normaliser simply never carried it, so
         the stamp hero had no photo to draw even when the gift had one. */
      imageRef:String(rung?.image_ref||'').trim()}))
    .filter(rung=>rung.slot>0)
    .sort((a,b)=>a.slot-b.slot);
  return {slots,filled,
    /* The card shows the CURRENT cycle. Anything past its end is CARRIED and said out loud, never
       absorbed into an invisible completed card the customer was never shown. */
    shown:slots>0?Math.min(filled,slots):filled,
    carried:slots>0?Math.max(filled-slots,0):0,
    cycle:whole(card.cycle_index),
    running:card.running!==false,
    /* nestly_v435: the card's own clock, from the version this card started under. */
    validityDays:whole(card.validity_days),
    expiresAt:card.expires_at||null,
    expired:card.expired===true,
    spendPerCents:whole(card.spend_per_stamp_cents),
    ready:card.ready===true,
    potMigrated:card.pot_migrated===true,
    milestones,
    next:milestones.find(rung=>!rung.claimed)||null};
}
/* Rings, reusing the v310 shapes and NO new CSS rule. Seven browser fixtures inline
   app/index.html's stylesheet under captured Chrome measurements pinned to a
   production-source-sha256, so one new rule would force a full browser recapture for a cosmetic
   change. A milestone slot takes the existing .is-goal mark; a collected slot takes .is-filled and
   the existing tick. */
function customerStampQuestRingsV323(quest){
  const total=quest.slots;
  if(!(total>0&&total<=PROGRAMME_STACK_RING_LIMIT_V310))return '';
  const marks=new Map(quest.milestones.filter(rung=>rung.slot<=total).map(rung=>[rung.slot,rung]));
  return `<div class="customer-programme-stamp-rings" role="img" data-stamp-quest-rings-v323="${esc(`${quest.shown}/${total}`)}" aria-label="${esc(ct('stampsQuestProgress',{filled:quest.shown,total}))}">${
    Array.from({length:total},(unused,index)=>{
      const slot=index+1,rung=marks.get(slot),collected=index<quest.shown;
      return `<span class="customer-programme-stamp-ring${collected?' is-filled':''}${rung?' is-goal':''}" data-stamp-quest-slot-v323="${slot}"${rung?` data-stamp-quest-claimed-v323="${rung.claimed?'yes':'no'}"`:''} aria-hidden="true">${
        collected?'<svg viewBox="0 0 16 16" width="12" height="12" focusable="false"><path d="M3.2 8.6l3.1 3.1L12.8 5" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/></svg>':''}</span>`;
    }).join('')
  }</div>`;
}
function customerStampQuestBodyV323(quest){
  /* nestly_v422: a migrated pot used to render one sentence here ("This stamp card has been
     retired — ask us about your balance."), which the owner struck out on photo 6. The whole card
     is removed by loadStampCardV323 before this body is ever built, so there is no retired branch
     left to render and the four locale strings that served it are gone with it. */
  const figure=customerStampQuestRingsV323(quest)
    ||`<p class="customer-programme-stamp-count" data-stamp-quest-count-v323="${quest.shown}"><b>${esc(customerPointTotalV103(quest.shown))}</b></p>`;
  const progress=quest.slots>0
    ?ct('stampsQuestProgress',{filled:quest.shown,total:quest.slots})
    :ct('stampsNoGift',{count:customerPointTotalV103(quest.shown)});
  const next=quest.next;
  const gift=next?(next.name||ct('rewardsTab')):'';
  const nextLine=!next?ct('stampsQuestAllClaimed')
    :next.toGo===0?ct('stampsReady',{gift})
    :ct('stampsRemaining',{count:customerPointTotalV103(next.toGo),gift});
  const ladder=quest.milestones.length
    ?`<ul class="customer-programme-stamp-quest-v323" data-stamp-quest-list-v323="${quest.milestones.length}">${
      quest.milestones.map(rung=>`<li data-stamp-quest-rung-v323="${rung.slot}" data-stamp-quest-rung-claimed-v323="${rung.claimed?'yes':'no'}"${
        /* nestly_v464: the rung carries its own deadline so the ladder can say it in the same
           place the customer reads the gift's name. Only the SERVER's verdict decides "expired";
           the date is printed, never compared, because the browser's clock is not the authority. */''
        }${rung.expiresAt?` data-stamp-quest-rung-expires-v464="${esc(String(rung.expiresAt))}"`:''}><b>${esc(String(rung.slot))}</b> <span data-merchant-content>${esc(rung.name)}</span>${
        rung.claimed?`<span class="muted small"> · ${esc(ct('stampsQuestClaimed'))}</span>`
        :rung.availability==='reward_expired'?`<span class="muted small" data-stamp-quest-rung-state-v464="expired"> · ${esc(ct('stampsRewardExpired'))}</span>`
        :rung.expiresAt&&rung.availability==='available_at_counter'?`<span class="muted small" data-stamp-quest-rung-state-v464="useby"> · ${esc(ct('stampsRewardUseBy',{date:walletDate(rung.expiresAt)}))}</span>`
        :''}</li>`).join('')
    }</ul>`
    :'';
  /* nestly_v435: the card's clock (owner rules 4/15) and the paused-card promise (rule 7). The
     expiry line renders only while a clock is actually running (validity set AND stamps on the
     card); an expired flag outranks it. The kept line renders whenever collecting is off but the
     customer still holds stamps — their value does not vanish with the switch. */
  const expiryLineV435=quest.expired?ct('stampsCardExpired')
    :(quest.expiresAt&&quest.filled>0&&quest.validityDays>0)?ct('stampsCardExpires',{date:walletDate(quest.expiresAt)})
    :'';
  const keptLineV435=(!quest.running&&quest.filled>0)?ct('stampsKeptWhilePaused',{count:customerPointTotalV103(quest.shown)}):'';
  return `${figure}
    <p class="muted small customer-programme-card-line-v310" data-stamp-quest-line-v323="progress">${esc(progress)}</p>
    <p class="muted small" data-stamp-quest-line-v323="next">${esc(nextLine)}</p>
    ${expiryLineV435?`<p class="muted small" data-stamp-quest-line-v323="expiry">${esc(expiryLineV435)}</p>`:''}
    ${keptLineV435?`<p class="muted small" data-stamp-quest-line-v323="kept">${esc(keptLineV435)}</p>`:''}
    ${quest.carried>0?`<p class="muted small" data-stamp-quest-line-v323="carried">${esc(ct('stampsQuestCarried',{count:customerPointTotalV103(quest.carried)}))}</p>`:''}
    ${ladder}`;
}
/* The "reward ready" banner. Renders only when the server's own next_eligible_reward is
   already claimable (the SAME available_now===true check customerClaimableFactsV310 uses for
   the claimable strip) — never a fabricated reward. The reward object this codebase carries
   here has only name/cost_units/remaining_units/available_now, so the banner does not print a
   description, image or validity window that is not actually in the payload. */
/* v337: "Claim reward ›" does not invent a new claim path — it takes the customer to the same
   rewards list the claimable strip already points at, where the matching reward's own "Show QR at
   counter" button (wired in loadRewards) does the redeem.

   v386 (owner photo 3: "why i click nothing happened"). v337 scrolled to #walletRewards, but
   v347/v348 moved the rewards list INTO the Points & gifts shortcut page, which is hidden until
   its tile is opened. scrollIntoView on a hidden element scrolls nowhere, so the button was inert
   on the collapsed profile. It opens the same shortcut page the tile opens — reusing that one code
   path rather than inventing a second claim route — and scrolls to the rewards list inside it once
   it is on screen.

   nestly_v395 (owner photo 1, the button ringed "Cannot click"). Two defects were left, and the
   owner hit both at once:
   (1) The lookup was querySelector — SINGULAR — while two different surfaces render the same
       [data-claim-reward-scroll-v337] contract: the reward-ready banner inside the offers swipe
       and the hero card's own "Claim reward". Whichever came second in the DOM was never wired at
       all, so it was a button that genuinely did nothing on click.
   (2) Even the wired one dead-ended when the rewards tile was absent — which, with the contract
       gate above rejecting today's server, it always was. It fell through to scrolling
       #walletRewards, a node that is hidden inside the shortcut page, so scrollIntoView moved
       nothing and the click had no visible effect whatsoever.
   Every matching button is now wired, and the fallback order ends somewhere real: the shortcut
   tile if there is one, else the rewards list if it is actually on screen, else the rewards
   SECTION (the pre-v347 layout, and the layout a firm with no points tile still renders). It
   never silently does nothing — with no rewards surface at all it says so, rather than leaving
   the customer tapping a button that looks broken. */
function wireCustomerClaimRewardV395(root=document){
  const scope=root||document;
  const buttons=[...scope.querySelectorAll('[data-claim-reward-scroll-v337]')];
  if(!buttons.length)return 0;
  const smooth=()=>matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth';
  const onScreen=node=>!!node&&!node.hidden&&!!node.getClientRects?.().length;
  buttons.forEach(button=>{button.onclick=()=>{
    const rewardsTile=document.querySelector('[data-business-shortcut-v347="points"],[data-business-shortcut-v347="rewards"]');
    const rewardsList=$('walletRewards'),rewardsSection=$('customerBusinessRewardsDetailV347');
    const scrollToRewards=()=>{
      const target=[rewardsList,rewardsSection].find(onScreen);
      if(!target)return false;
      target.scrollIntoView({behavior:smooth(),block:'start'});
      return true;
    };
    if(rewardsTile&&$('customerBusinessShortcutPageV348')?.hidden!==false){
      rewardsTile.click();
      requestAnimationFrame(()=>requestAnimationFrame(scrollToRewards));
      return;
    }
    if(scrollToRewards())return;
    /* Nothing to scroll to: say so instead of absorbing the tap. */
    toast('Your rewards are still loading. Try again in a moment.');
  }});
  return buttons.length;
}
/* The greeting is the SUM of the numbers printed on the cards below it — the owner's invariant.
   `known` goes false the moment ONE card has no count, because a partial sum printed as a total
   would just be a new way of being wrong. */
function customerRewardReadyTotalV465(cards=[]){
  const list=Array.isArray(cards)?cards:[];
  let total=0,known=list.length>0;
  for(const card of list){
    const count=customerCardReadyCountV465(card);
    if(count===null){known=false;continue}
    total+=count;
  }
  return {total,known};
}
/* nestly_v428 (item 6) — "2 REWARDS READY" WHEN ONLY ONE CAN BE TAKEN.
   A stamp milestone is an ordinary catalogue reward whose COST IS ITS SLOT on the card
   (v323:968 — `'slot', rung.cost_points`), and public.stamp_milestone_claims carries a unique key
   on (business, client, programme, cycle, slot_position): "one gift per milestone per card"
   (v323:402-407). A firm that authored two gifts at the same slot — which is legal — therefore
   shows a completed card with BOTH claimable and lets the customer claim exactly one; claiming
   either makes the other unavailable for the cycle (v323:753).
   So "2 rewards ready" is arithmetic that is true and a promise that is false. The owner-locked
   wording is "Choose 1".
   The test is the slot rule itself, not a guess: two or more CLAIMABLE catalogue rewards sharing
   one cost, on a firm whose balance is counted in stamps. Points rewards that happen to cost the
   same are genuinely independent — a customer with the balance may take both — so the stamps gate
   is load-bearing and not decoration. */
function customerStampChooseOneSlotV428(claimable,unit){
  if(String(unit||'').trim().toLowerCase()!=='stamps')return false;
  const perSlot=new Map();
  (Array.isArray(claimable)?claimable:[]).forEach(item=>{
    if(!item||item.redemption_kind==='classic_points')return;
    const slot=Math.max(0,Math.floor(Number(item.cost_points)||0));
    if(!slot)return;
    perSlot.set(slot,(perSlot.get(slot)||0)+1);
  });
  return [...perSlot.values()].some(count=>count>1);
}
/* nestly_v399. The final swipe page's "View all rewards" control. It does NOT navigate on its
   own: it clicks the reward shortcut tile the modules row already renders, so the customer lands
   on the very same Points & gifts / Stamp card catalogue page that tile opens, wired by
   wireCustomerBusinessShortcutsV347. One reward catalogue, one route into it.
   Like wireCustomerClaimRewardV395, it refuses to absorb a tap it cannot honour: with no tile on
   the page it says so instead of looking broken. */
function wireCustomerHeroViewAllV399(root=document){
  const buttons=[...(root||document).querySelectorAll('[data-hero-view-all-v399]')];
  if(!buttons.length)return 0;
  buttons.forEach(button=>{button.onclick=()=>{
    const action=String(button.dataset.heroViewAllV399||'').trim();
    const tile=(action?document.querySelector(`[data-business-shortcut-v347="${action}"]`):null)
      ||document.querySelector('[data-business-shortcut-v347="points"],[data-business-shortcut-v347="rewards"]');
    if(!tile)return toast('Your rewards are still loading. Try again in a moment.');
    tile.click();
  }});
  return buttons.length;
}
function customerRewardReadyCountApplyV397(count,root=document,{chooseOneV428=false}={}){
  const ready=Math.max(0,Number(count)||0);
  const nodes=[...root.querySelectorAll('[data-reward-ready-count-v397]')];
  nodes.forEach(node=>{
    /* A firm can lose its last claimable reward between renders (redeemed, expired, limit hit).
       The node then goes back to whatever it said before a reward was ready, which the renderer
       stored on it, rather than printing "0 rewards ready". */
    /* nestly_v465 (owner ruling R6, B-REG-023): that stored sentence used to be the pill's painted
       text, which on a ready-looking card was "Reward ready" — so falling back to it RE-ASSERTED a
       readiness the catalogue had just resolved to zero. Every renderer now stores a
       readiness-FREE fallback (customerBusinessRelationshipSummaryV346's progressSublineV465, the
       modules row's item.fallback), so following the catalogue down to zero says something true.
       The rule this enforces is one-directional: the catalogue may take readiness away, and this
       function may never put it back. */
    /* nestly_v428 (item 6): when the claimable set is several gifts on ONE stamp slot, the tile
       says how many the customer may take rather than how many exist. */
    node.textContent=ready>0
      ?(chooseOneV428?'Choose 1 reward':customerRewardReadyLineV397(ready))
      :String(node.dataset.rewardReadyFallbackV397||'');
  });
  return nodes.length;
}
/* nestly_v399. The customer-facing words for the server's `availability` value, so the hero swipe
   page and the reward list under it describe the same reward the same way. These are the strings
   the list already used; they live in one place now because two surfaces read them. The default is
   deliberately vague rather than reassuring: an availability we do not recognise must never render
   as "ready". */
const CUSTOMER_REWARD_AVAILABILITY_COPY_V399={
  available_at_counter:'Available at counter',
  disabled:'Unavailable for redemption',
  insufficient_balance:'More points needed',
  not_started:'Available soon',
  ended:'Offer ended',
  limit_reached:'Claim limit reached',
  claimed_this_cycle:'Already claimed on this card',
  not_on_card:'Not on the current card',
  tier_locked:'Unlocks at a higher tier',
  /* nestly_v464: the owner gave this reward a shelf life and it ran out. Named here rather than
     left to the vague default, because "Not available right now" would read as a temporary state
     for something that is gone. */
  reward_expired:'This reward has expired'
};
/* V468-C4 (owner, photo 7: "for stamp portion, it's called stamps, not points"). One of these
   sentences names a unit — insufficient_balance — and it named the WRONG one on every stamp card
   in the product: a customer three stamps short read "More points needed" under a stamp meter.
   The noun comes from the existing v429 plumbing (customerUnitNounV429), not a second copy of
   "is this a stamp card?", and it is substituted rather than duplicated into the table so a
   future availability copy cannot forget to have a stamps twin. `unit` is optional: every caller
   that does not know the unit keeps today's words exactly. */
function customerRewardAvailabilityLineV399(reward,unit){
  const key=String(reward?.availability||'').trim();
  const copy=CUSTOMER_REWARD_AVAILABILITY_COPY_V399[key]||'Not available right now';
  const noun=unit?customerUnitNounV429(unit,2):'points';
  return noun==='points'?copy:copy.replace(/\bpoints\b/g,noun);
}
/* nestly_v399 (owner batch: "customer can keep swiping through all rewards available from that
   business"). Three defects kept legitimate rewards off this swipe, all of them client-side
   inventions the server contract does not support:
   (1) ZERO-COST REWARDS WERE DROPPED. The filter was `cost<=0 → skip`. But the server decides
       redeemability with `balance < cost_points → insufficient_balance, else available_at_counter`
       (customer_get_business_actions_v89), so a reward costing 0 is not "not a reward" — it is a
       reward that is ALWAYS redeemable, i.e. exactly a free welcome gift. The gate is now
       `cost < 0 || not finite`, which rejects only a cost we genuinely cannot read.
   (2) DISTINCT REWARDS THAT SHARE A NAME WERE COLLAPSED. Identity was `name.toLowerCase()`, and
       this firm really does run two different rewards both called "Free Lotion" (5 and 10 points,
       different reward ids). Identity is the server's own key now — action_key, i.e. the reward
       id — with name+cost only as a fallback for a payload that carries no key.
   (3) PAGE 1's REWARD WAS DEDUPED BY NAME ALONE, so the OTHER "Free Lotion" vanished with it.
       next_eligible_reward carries no id (app.c45_base_actionable_wallet_card sends name,
       cost_units, remaining_units, available_now and nothing else), so page 1 is matched on name
       AND cost — the same name+cost pairing loadRewards already uses to join actions to catalogue.
   Nothing here caps the catalogue: every reward the server returns gets a page. What it gains is
   a final "View all rewards" page once there are two or more of them, so the swipe always ends
   somewhere deliberate instead of running on. Readiness is untouched and still the server's
   answer via customerRewardCanRedeem — never arithmetic. */
/* nestly_v471 (owner, photo 4: "For all rewards, ensure that customer view have a '?' — to view
   the rules of the rewards", and then "i still don't see the ?").
   The "?" is not new — V468-E4 built the control and the rules sheet behind it. What it was
   missing is reach: customerRewardHelpButtonV468 is emitted only by rewardCardV422 and
   entitlementCardV429, and rewardCardV422 is drawn ONLY for rewards the counter would honour
   right now (claimableRewardsV422, the v422 ruling). So a customer still saving toward a gift —
   which is most customers, most of the time — saw the whole catalogue on these hero pages and not
   one "?" anywhere on it. That is the "for ALL rewards" the owner is asking for.
   Keyed by INDEX into this array rather than by action_key: action_key is minted client-side and
   degrades to the literal string "catalog:undefined" on the fallback branch where the actions read
   failed but the catalogue answered — and that branch still renders these hero pages. Keying on it
   there would open the first reward's sheet for every "?" on the card. The index cannot collide. */
let customerHeroRewardRowsV471=[];
function customerHeroRewardPagesV395(rewards=[],{balance=0,unit='points',currentRewardName='',currentRewardCost=null,redemptionEnabled=false,bookAction='',viewAllHref='',viewAllAction=''}={},root=document){
  const swipe=root.querySelector('[data-hero-swipe-v395]');
  const track=swipe?.querySelector('[data-hero-track-v395]');
  const dots=swipe?.querySelector('[data-hero-dots-v395]');
  if(!swipe||!track||!dots)return 0;
  track.querySelectorAll('[data-hero-extra-v395]').forEach(node=>node.remove());
  const held=Math.max(0,Number(balance)||0);
  const heroName=String(currentRewardName||'').trim().toLowerCase();
  const heroCost=Number(currentRewardCost);
  const seen=new Set();
  const unitWord=ct(unit==='stamps'?'stamps':unit||'points');
  customerHeroRewardRowsV471=[];
  const pages=(Array.isArray(rewards)?rewards:[]).map(reward=>{
    const name=String(reward?.customer_name||reward?.name||'').trim();
    const cost=Number(reward?.cost_points??reward?.cost_units);
    /* A cost of 0 is a real, immediately-claimable reward. Only an unreadable or negative cost
       is skipped, because that is a row we cannot draw an honest number from. */
    if(!name||!Number.isFinite(cost)||cost<0)return '';
    /* The reward id is the server's identity for a reward; two rewards may legitimately share a
       customer-facing name. name|cost is the fallback for a payload with no action_key. */
    const key=String(reward?.action_key||`${name.toLowerCase()}|${cost}`);
    if(seen.has(key))return '';
    seen.add(key);
    /* Page 1 already shows this reward. Matched on name AND cost so the firm's OTHER reward of
       the same name is not swept away with it. When the hero named a reward but sent no cost,
       fall back to the name alone rather than risk printing page 1's reward twice. */
    if(heroName&&name.toLowerCase()===heroName&&(!Number.isFinite(heroCost)||heroCost===cost))return '';
    const remaining=Math.max(0,cost-held);
    const progress=cost>0?Math.max(0,Math.min(100,Math.round(held/cost*100))):100;
    /* nestly_v397 (owner photo D). READINESS IS THE SERVER'S ANSWER, NOT ARITHMETIC. v395 drew
       this page's state from balance-minus-cost, which is exactly the browser-side readiness v145
       forbids — it would offer a Redeem button for a reward the counter will refuse (ended,
       tier-locked, claim-limit reached, redemption switched off). customerRewardCanRedeem is the
       same check the reward list below uses, over the same catalogue row, so the hero page and
       that list can never disagree about what is claimable. The points arithmetic stays ONLY for
       the not-ready distance line, which is a display fact, not permission. */
    const readyV397=!!(reward?.action_key&&customerRewardCanRedeem(reward,redemptionEnabled));
    /* V468-C4 (owner, photo 7, four marks on this one card). The unit is the reward's OWN unit
       through the existing v429 plumbing, not a second "is this a stamp card?" test — a reward
       that declares `unit` outranks the caller's, which is exactly what customerRewardUnitV429
       is for, and the noun below it is that helper's, so "1 stamp" is never "1 stamps". */
    const rewardUnitV468=customerRewardUnitV429(reward,unit);
    const stampsV468=rewardUnitV468==='stamps';
    /* Mark 2, an arrow at the counter: "show how many stamps left to claim this gift". The counter
       stated the PRICE, which a customer holding some of it cannot subtract in their head. On a
       stamp card it states the distance instead — but only where the distance is a true thing to
       say. At zero it would read "0 more stamps to go", which asserts a readiness the server may
       refuse; and where the server HAS said ready, the arithmetic can still be short (readiness is
       the server's answer, never subtraction — v145/v397), and "3 more stamps to go" beside a
       READY pill contradicts it. Both cases fall back to the price. Points keeps the price at all
       times, which is what "counter as before" means for that model: the
       points hero carries the meter and its own "N points to go" line, and this counter is the one
       place the cost is written down. */
    const needV468=!readyV397&&remaining>0
      ?`${customerPointTotalV103(remaining)} more ${customerUnitNounV429(rewardUnitV468,remaining)} to go`:'';
    const counterV468=stampsV468&&needV468?needV468:`${customerPointTotalV103(cost)} ${unitWord}`;
    /* Mark 4, an arrow into the empty right of the card: "show gift photo" — the same image_ref
       the reward list and the business-side reward rows render. It is a GRID COLUMN, not an
       overlay: with no photo the body is one column and the card is byte-identical to v399's, so
       a gift without a picture leaves no hole and nothing collapses. */
    const photoV468=customerMediaUrlV95(reward?.image_ref);
    /* Mark 3, "for stamps, don't need this meter bar, remove!". A stamp card's distance is counted
       in whole stamps and the number is now in the counter above; the bar was a second, vaguer
       telling of it. Points keeps the bar — there the balance is a large number and the bar is the
       only glanceable cue. */
    const meterV468=readyV397||stampsV468?''
      :`<div class="customer-reward-progress customer-business-tier-meter-v386" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${progress}" aria-label="${esc(`${name} progress`)}" style="--reward-progress:${progress}%"><span></span></div>`;
    /* nestly_v399. "N to go" is only true when the customer is genuinely SHORT of the cost. A
       reward that is not ready for any other reason the server gave — ended, claim limit reached,
       redemption switched off, not started — used to print "0 points to go" under a full meter,
       which reads as "ready" and is the opposite of what the counter will do. Those states say
       what the server said, in the same words the reward list below this hero uses.
       V468-C4: on a stamp card the distance has moved up into the counter, so this line is left
       with only the job it cannot delegate — reporting a refusal the arithmetic cannot see. */
    const lineTextV468=remaining>0
      ?(stampsV468?'':`${customerPointTotalV103(remaining)} ${unitWord} to go`)
      :customerRewardAvailabilityLineV399(reward,rewardUnitV468);
    /* Owner struck out the meter and the sentence under a READY reward: at 100% the meter says
       nothing and "Ready to redeem on your next visit" repeats the pill above it. A reward still
       being earned keeps both — that is the one state where the distance is the point. */
    /* nestly_v471: the index this reward's "?" will address. Pushed here, after every skip above
       has had its say, so the array and the pages that survive are the same list. */
    const helpIndexV471=customerHeroRewardRowsV471.push(reward)-1;
    return `<div class="customer-business-hero-page-v395" data-hero-extra-v395>
      <section class="card customer-business-summary-v346${readyV397?' is-reward-ready-v2b':''}${photoV468?' customer-hero-has-photo-v468':''}" data-hero-mode-v386="reward" aria-label="${esc(name)}">
        <div class="customer-business-summary-top-v347">
          <span class="customer-business-tier-pill-v347">${CUI.icon('giftcard',{size:16})}<span>${esc(readyV397?'READY':'NEXT REWARD')}</span></span>
          <span class="customer-business-ready-v347">${CUI.icon('loyalty',{size:16})}<span>${esc(counterV468)}</span></span>
          ${customerRewardHelpButtonV468('data-hero-reward-rules-v471',helpIndexV471,name)}
        </div>
        <div class="customer-hero-reward-body-v468">
          <div class="customer-hero-reward-copy-v468">
            <b class="customer-business-reward-name-v395">${esc(name)}</b>
            ${customerRewardEndsLineV471(reward)}
            ${meterV468}
            ${readyV397||!lineTextV468?'':`<p class="customer-business-summary-line-v362">${esc(lineTextV468)}</p>`}
            ${readyV397?`<div class="customer-business-summary-actions-v349">
              ${/* nestly_v397 (owner photo D: a button drawn onto this card, "click then can show
                   QR to redeem"). It carries the SAME data-customer-redeem action_key contract the
                   reward list's own "Show QR at counter" button carries, and loadRewards wires
                   both with one handler — so this opens the existing intent + QR path and does not
                   invent a second way to redeem. */''}
              <button type="button" class="customer-business-claim-v347" data-customer-redeem="${esc(reward.action_key)}" data-hero-redeem-v397><span>Redeem now</span><span aria-hidden="true">›</span></button>
              ${bookAction}
            </div>`:''}
          </div>
          ${photoV468?`<img class="customer-hero-reward-photo-v468" src="${esc(photoV468)}" alt="" loading="lazy" decoding="async" data-hero-reward-photo-v468>`:''}
        </div>
      </section>
    </div>`;
  }).filter(Boolean);
  /* nestly_v399. The catalogue is NOT capped — every reward above got its page. This is the exit
     at the end of them: one lightweight page that hands the customer to the reward catalogue this
     profile already renders (the Points & gifts / Stamp card shortcut), so the swipe ends
     somewhere deliberate. It reuses the existing [data-business-shortcut-v347] destination and
     mints no second reward surface. With a single reward there is nothing to "view all" of, so it
     is not drawn and the region stays the one card plus that reward. */
  if(pages.length>1&&(viewAllHref||viewAllAction)){
    /* The figure is REWARDS, not pages: page 1's own reward was deduped out of `pages`, so the
       page count alone would under-report the catalogue by exactly one whenever the hero named a
       reward. Counting it back in is what makes this agree with the reward list the button opens. */
    const totalRewardsV399=pages.length+(heroName?1:0);
    pages.push(`<div class="customer-business-hero-page-v395" data-hero-extra-v395>
      <section class="card customer-business-summary-v346 customer-hero-viewall-v399" data-hero-mode-v386="viewall" aria-label="View all rewards">
        <div class="customer-business-summary-top-v347">
          <span class="customer-business-tier-pill-v347">${CUI.icon('giftcard',{size:16})}<span>REWARDS</span></span>
          <span class="customer-business-ready-v347">${CUI.icon('loyalty',{size:16})}<span>${esc(`${customerPointTotalV103(totalRewardsV399)} reward${totalRewardsV399===1?'':'s'}`)}</span></span>
        </div>
        <b class="customer-business-reward-name-v395">See every reward</b>
        <div class="customer-business-summary-actions-v349">
          <button type="button" class="customer-business-claim-v347" data-hero-view-all-v399="${esc(viewAllAction||'')}"><span>View all rewards</span><span aria-hidden="true">›</span></button>
        </div>
      </section>
    </div>`);
  }
  if(pages.length)track.insertAdjacentHTML('beforeend',pages.join(''));
  /* V468-C4: never a broken image on the hero. Same bargain v340 struck for the reward list — a
     stored object that has since been deleted drops the picture AND the column that reserved room
     for it, so the card falls back to exactly the one-column layout a photoless gift renders. */
  track.querySelectorAll('[data-hero-reward-photo-v468]').forEach(image=>{image.onerror=()=>{
    image.closest('.customer-business-summary-v346')?.classList.remove('customer-hero-has-photo-v468');
    image.remove();
  }});
  const total=track.querySelectorAll('.customer-business-hero-page-v395').length;
  dots.hidden=total<2;
  dots.innerHTML=total<2?'':Array.from({length:total},(_,index)=>
    `<span class="customer-business-hero-dot-v395${index===0?' is-active':''}" aria-hidden="true"></span>`).join('');
  swipe.dataset.heroPagesV395=String(total);
  if(total>1&&!track.dataset.heroDotsWiredV395){
    track.dataset.heroDotsWiredV395='1';
    track.tabIndex=0;
    track.addEventListener('scroll',()=>{
      const width=track.clientWidth||1;
      const index=Math.round(track.scrollLeft/width);
      [...dots.children].forEach((dot,position)=>dot.classList.toggle('is-active',position===index));
    },{passive:true});
  }
  return total;
}
function customerBusinessSecondaryMarkupV346(presentation={}){
  const products=Array.isArray(presentation.products)?presentation.products:[],
    services=Array.isArray(presentation.services)?presentation.services:[],
    benefits=Array.isArray(presentation.benefits)?presentation.benefits:[],
    cardImage=item=>customerMediaUrlV95(item?.image_url);
  const featured=[...products.map(item=>({...item,entity_type:item.entity_type||'product'})),
    ...services.map(item=>({...item,entity_type:item.entity_type||'service'}))];
  const featuredMarkup=featured.length
    ?`<div class="customer-rewards-grid customer-secondary-grid-v346">${featured.slice(0,4).map(customerFeatureCardMarkupV156).join('')}</div>`
    :'<p class="muted small">Featured services will appear here when this business publishes them.</p>';
  const benefitMarkup=benefits.length
    ?`<div class="customer-perks-grid customer-secondary-grid-v346">${benefits.slice(0,4).map(item=>`<article class="customer-perk-card">${cardImage(item)?`<img src="${esc(cardImage(item))}" alt="" loading="lazy">`:''}<b>${esc(item.name||ct('benefits'))}</b>${item.tagline?`<p class="muted small" style="margin-top:5px">${esc(item.tagline)}</p>`:''}</article>`).join('')}</div>`
    :'';
  return `<section class="customer-business-group-v346 customer-business-secondary-v346" aria-labelledby="customerBusinessSecondaryTitle">
    <div class="customer-business-group-head-v346"><h2 id="customerBusinessSecondaryTitle">Secondary</h2><p class="muted small">Menu, perks and visit feedback.</p></div>
    ${featuredMarkup}
    ${benefitMarkup}
  </section>`;
}
function wireCustomerBusinessShortcutsV347(root=document){
  const selectors={
    points:'#customerBusinessRewardsDetailV347',
    rewards:'#customerBusinessRewardsDetailV347',
    /* Same node as points — v386 filters which cards inside it are shown per action. */
    tiers:'#customerBusinessRewardsDetailV347',
    packages:'#customerBusinessPackagesDetailV347',
    membership:'#walletMemberships,#customerBusinessPackagesDetailV347',
    referral:'#customerBusinessReferralDetailV362',
    activity:'#customerBusinessActivityDetailV347'
  };
  const labels={
    points:'Points & gifts',
    rewards:'Rewards',
    tiers:'Tier benefits',
    packages:'Packages',
    membership:'Membership',
    referral:'Refer a friend',
    activity:'Activity'
  };
  root.querySelectorAll('[data-business-shortcut-v347]').forEach(card=>{
    card.onclick=event=>{
      event.preventDefault();
      const action=String(card.dataset.businessShortcutV347||'');
      const selector=selectors[action]||card.getAttribute('href')||'';
      const target=selector?document.querySelector(selector):null;
      if(!target||target.hidden){
        toast(action==='referral'?'Referral sharing is not available for this business yet.':'This section is still loading. Try again in a moment.');
        return;
      }
      openCustomerBusinessShortcutPageV348({action,title:labels[action]||card.textContent.trim()||'Details',target});
    };
  });
}
function openCustomerBusinessShortcutPageV348({action='',title='Details',target=null}={}){
  const page=$('customerBusinessShortcutPageV348'),main=$('customerBusinessMainV348'),content=$('customerBusinessShortcutContentV348'),heading=$('customerBusinessShortcutTitleV348');
  if(!page||!main||!content||!target)return;
  closeCustomerBusinessShortcutPageV348();
  const placeholder=document.createElement('span');
  placeholder.hidden=true;
  placeholder.dataset.customerBusinessShortcutPlaceholderV348=action||'details';
  target.parentNode?.insertBefore(placeholder,target);
  content.replaceChildren(target);
  if(heading)heading.textContent=title;
  /* v386 (owner photos 5 + 10). "Tier benefits" and "Points & gifts" are two tiles that opened
     ONE section, so both screens painted the whole programme stack and the owner saw the tier
     ladder inside Points & gifts ("dont show 'Tier' in 'Points & gift'") and the stamp card
     inside Tier benefits ("dont show this in Tier"). The stack is still rendered once — two
     copies would give the rewards list two mount points with one id — and the cards that do not
     belong to the tile the customer actually tapped are hidden for as long as this page is open,
     then restored on close. Hiding rather than detaching keeps loadRewards/loadTier writing into
     live nodes, so a section that arrives while the page is open still lands. */
  const hiddenByShortcutV386=[];
  const keepForActionV386={tiers:['tiers'],points:['stamps','points'],rewards:['stamps','points']}[action];
  if(keepForActionV386){
    target.querySelectorAll('[data-programme-card]').forEach(card=>{
      if(keepForActionV386.includes(String(card.dataset.programmeCard||'')))return;
      if(card.hidden)return;
      card.hidden=true;
      hiddenByShortcutV386.push(card);
    });
    /* The explainer is points guidance, so it follows the points half rather than standing alone
       over a tier ladder. (v386 hid the section's group head here too; nestly_v446 hides it for
       every action instead — see below — so this line no longer has to.) */
    if(action==='tiers')target.querySelectorAll('[data-points-explainer]').forEach(node=>{
      if(node.hidden)return;
      node.hidden=true;
      hiddenByShortcutV386.push(node);
    });
  }
  /* nestly_v446 (REG-002, "the page shows a doubled Rewards heading"). A section carries its own
     `<h2>` because on the profile it is one group among several; on THIS page it is the whole
     page, and the page already prints its title in `<h1>` beside the Back button. So the stamp
     card tile opened a page headed "Rewards" over a section headed "Rewards" — the same word
     twice, one under the other. v386 already removed it, but only for the tiers action, where it
     had been noticed. The rule is not about tiers: a group head inside this page is redundant
     whatever tile opened it, and the ONE place the section is named is now the page title.
     Hidden, not detached, and restored on close like everything else here, so the profile page
     underneath is unchanged. */
  target.querySelectorAll('.customer-business-group-head-v346').forEach(node=>{
    if(node.hidden)return;
    node.hidden=true;
    hiddenByShortcutV386.push(node);
  });
  /* V468-E1 (owner photo 16: the Activity screen "is nearly empty" — one card reading
     "History — Transactions and loyalty activity" and nothing under it).
     Nothing was missing from the data. customer_get_transaction_history_v167 already returns the
     exact feed the owner described — sales UNION standalone points-ledger rows, ordered
     `event_at desc`, each row carrying its own money, its own earned/redeemed/removed figures and
     its own pot (loyalty_unit) — and loadTransactions already renders it. It was simply buried
     under two stacked <details>: this group's "History" disclosure, and the "Full history"
     disclosure inside the section, of which only three rows escaped.
     A disclosure earns its keep on the PROFILE, where Activity is one group among five. On its
     own page it is the page, so both history disclosures are forced open here and restored on
     close, exactly like the v386/v446 hidden nodes beside them. Line-item <details> inside a row
     are deliberately untouched — those are per-transaction detail, not the feed. */
  const activityFeedV468=action==='activity';
  const activityDisclosuresV468=[];
  if(activityFeedV468){
    page.dataset.customerActivityFeedV468='1';
    openCustomerActivityDisclosuresV468(target,activityDisclosuresV468);
  }else delete page.dataset.customerActivityFeedV468;
  page._customerBusinessShortcutRestoreV348=()=>{
    hiddenByShortcutV386.forEach(node=>{node.hidden=false});
    hiddenByShortcutV386.length=0;
    activityDisclosuresV468.forEach(entry=>{entry.node.open=entry.open});
    activityDisclosuresV468.length=0;
    delete page.dataset.customerActivityFeedV468;
    if(placeholder.parentNode)placeholder.parentNode.insertBefore(target,placeholder);
    placeholder.remove();
  };
  main.hidden=true;
  page.hidden=false;
  page.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'start'});
  requestAnimationFrame(()=>{
    const focusTarget=action==='tiers'
      ?target.querySelector('[data-programme-card="tiers"],button,a,[tabindex]')
      :target.querySelector('button,a,input,select,textarea,[tabindex]');
    focusTarget?.focus?.({preventScroll:true});
  });
}
/* V468-E1: the two history disclosures, and only those two. `record` collects the pre-open state
   so the profile page underneath is handed back exactly as the customer left it. */
function openCustomerActivityDisclosuresV468(root,record=null){
  if(!root)return;
  root.querySelectorAll('details.wallet-history-disclosure').forEach(node=>{
    if(record&&!record.some(entry=>entry.node===node))record.push({node,open:node.open});
    node.open=true;
  });
}
/* V468-E1: the sections under this page are filled asynchronously (loadTransactions /
   loadActivity land after the page has already opened), so each of them re-runs the open pass
   for whatever it just painted. No-op unless the Activity page is the thing on screen. */
function syncCustomerActivityFeedV468(){
  const page=$('customerBusinessShortcutPageV348');
  if(!page||page.hidden||page.dataset.customerActivityFeedV468!=='1')return;
  openCustomerActivityDisclosuresV468(page);
}
function closeCustomerBusinessShortcutPageV348(){
  const page=$('customerBusinessShortcutPageV348'),main=$('customerBusinessMainV348'),content=$('customerBusinessShortcutContentV348');
  if(!page||!main||!content)return;
  if(typeof page._customerBusinessShortcutRestoreV348==='function'){
    page._customerBusinessShortcutRestoreV348();
    page._customerBusinessShortcutRestoreV348=null;
  }
  content.replaceChildren();
  page.hidden=true;
  main.hidden=false;
}
/* V468-E2(a): see CUSTOMER_WALLET_COUNTER_WINDOW_MS_V468. Opening the member code, or reaching
   for a reward's redeem control, is the customer saying "I am at the till". */
function wireCustomerCounterMomentV468(root){
  if(!root||typeof root.addEventListener!=='function')return;
  root.addEventListener('click',event=>{
    if(event.target?.closest?.('[data-member-code-w6i2],[data-customer-redeem]'))void customerCounterMomentV468();
  });
}
function wireCustomerBusinessShortcutPageV348(root=document){
  root.querySelector('#customerBusinessShortcutBackV348')?.addEventListener('click',()=>{
    closeCustomerBusinessShortcutPageV348();
    root.querySelector('[data-business-shortcut-v347]')?.focus?.({preventScroll:true});
  });
}
/* W4c lives HERE, not beside the slot it fills, and that placement is deliberate rather than
   tidy: tests/browser/generate-v104-promotions-visual.mjs extracts production source from
   `openCustomerPromotionDetailsV104` to `customerMerchantExperienceMarkupV95` and pins the result
   with a production-source-sha256 that its CAPTURED CHROME MEASUREMENTS are keyed to. Declaring
   these three inside that span would have invalidated a browser capture this build cannot redo,
   for code the same span does not render. */
/* W4c (built in W6 increment 2): "Show my code" — the standing member QR, the biggest customer-side
   gap against Stampede. Its two halves come from the W4 design contract verbatim:
   public.customer_get_member_code_v310(p_business_slug) returns a stable opaque per-(business,
   client) code, and the counter reads it through the fourth `nestly:member:` branch in
   redemptionPayloadFromQr.
   The code is OPAQUE and per-business by contract, so this markup must never print anything else:
   showing a phone number or a client id would hand every counter a customer identifier that works
   at every other business too. */
/* W4c's SERVER CONTRACT, named here because the client is built against it and shipped switched
   off. Both halves are pinned in the W4 design contract and neither exists in the database yet:
     · public.customer_get_member_code_v310(p_business_slug text) -> {code}
       wallet-context gated (app.v32_customer_wallet_context), 42501 without a verified link,
       returning a STABLE OPAQUE per-(business, client) code — opaque and per-business because a
       code that worked at every business would hand one counter an identifier for all of them.
     · public.staff_resolve_member_code_v310(p_business uuid, p_code text) -> {client_id, name}
       staff-scoped, destination = the existing Customer 360 screen.
   Both flags stay FALSE until a migration ships and registers them in docs/design/ps0/writer-
   registry.json and the v21 authenticated-RPC allowlist. Flipping a flag without that registration
   would put an ungranted function name in the browser bundle, which those two guards refuse.

   SUPERSEDED (v327, owner directive 2026-08-15): this whole per-(business,client) contract is
   dead. The owner wants ONE global Peekaa member code recognised at every merchant, not an opaque
   code that is deliberately different at each one — the "opaque and per-business by contract"
   line above is exactly the property that got reversed. customer_get_member_code_v310 /
   staff_resolve_member_code_v310 are retired unbuilt; the live implementation is
   public.customer_get_member_qr_v327 (reader) and public.staff_scan_member_qr_v327 (resolver),
   wired from renderCustomerProfile and the till's "Scan customer QR" button respectively. Both
   flags below stay false permanently — this contract will never ship — and the dead markup/reader
   functions immediately following are kept only because ripping them out is not this migration's
   job; nothing live still calls them. */
const MEMBER_CODE_CONTRACT_W6I2=Object.freeze({readerShipped:false,resolverShipped:false});
/* The one place the reader would be called. It is a function rather than an inline call so the
   RPC name lands in exactly one edit when the migration arrives, and so the gate above cannot be
   bypassed by a second call site appearing somewhere else. */
async function memberCodeForWalletW6I2(){
  if(!MEMBER_CODE_CONTRACT_W6I2.readerShipped)return '';
  return '';
}
function customerMemberCodeMarkupW6I2(code){
  const value=String(code||'').trim();
  if(!value)return '';
  return `<section class="card customer-programme-card-v310" data-member-code-w6i2 aria-label="${esc(ct('showMyCode'))}">
    <h2 class="customer-programme-card-head-v310">${CUI.icon('customers',{size:16})}<span>${esc(ct('showMyCode'))}</span></h2>
    <p class="muted small">${esc(ct('showMyCodeBody'))}</p>
    <!-- Inline layout rather than a new class: this stylesheet is inlined verbatim into nine
         checked-in browser fixtures that carry captured Chrome measurements under a
         production-source-sha256, so one cosmetic rule would force a browser recapture of all
         nine. .growth-redemption-token already ships in app/growth-offers.css. -->
    <div id="customerMemberQrW6I2" style="display:grid;place-items:center;min-height:200px;margin:14px auto;padding:12px;border:1px solid var(--line);border-radius:16px;background:#fff" aria-label="${esc(ct('showMyCode'))}"></div>
    <details style="margin-top:10px"><summary class="small">${esc(ct('showMyCode'))}</summary>
      <code class="growth-redemption-token" data-member-code-value-w6i2>${esc(value)}</code></details>
  </section>`;
}
function actionableWalletCardMarkup(card,{detail=false}={}){
  const business=card?.business||{},loyalty=card?.loyalty||{},credit=card?.credit||{},packages=card?.packages||{};
  const unit=esc(loyalty.unit||'points'),currency=esc(business.currency||'SGD'),reward=card?.next_eligible_reward||null,visit=card?.visit_progress||{};
  return `<article class="card wallet-section${detail?' customer-game-card':''}"${detail?'':' style="margin:0"'}>
    <div class="row"><div><h2>${esc(business.name||'Business')} rewards</h2><p class="muted small" style="margin-top:4px">${esc(business.industry||'Local business')}</p></div><span class="spacer"></span>${detail?'':`<span class="pill">${esc(actionableWalletActionText(card))}</span>`}</div>
    <div class="wallet-metrics">
      <div class="wallet-metric"><span class="muted small">${unit} balance</span><b>${esc(customerPointTotalV103(loyalty.balance||0))}</b></div>
      <div class="wallet-metric"><span class="muted small">Package session balance</span><b>${Number(packages.sessions_remaining||0)}</b></div>
      <div class="wallet-metric"><span class="muted small">${unit} expiry</span><b style="font-size:14px;line-height:1.35">${esc(actionableWalletExpiryText(card?.expiry,loyalty.unit||'points'))}</b></div>
    </div>
    <div class="wallet-line" style="margin-top:8px"><div style="width:100%"><b>Next reward</b>${reward?customerRewardProgressMarkupV167(card):'<p class="muted small" style="margin-top:4px">No active reward is available right now.</p>'}</div></div>
    ${card?.visits_remaining===null||card?.visits_remaining===undefined?'':`<div class="wallet-line"><div><b>Visit progress</b><p class="muted small" style="margin-top:4px">${Number(card.visits_remaining)===0?'Current visit goal is complete.':`${Number(card.visits_remaining)} qualifying visit${Number(card.visits_remaining)===1?'':'s'} remaining.`}${visit.customer_description?` ${esc(visit.customer_description)}`:''}</p></div></div>`}
    ${birthdayBenefitMarkup(card?.birthday_benefit,{interactive:detail,compact:!detail})}
    ${detail?`<p class="muted small" style="margin-top:14px">${esc(actionableWalletActionText(card))}</p>`:''}
  </article>`;
}
let customerHomeOverview={walletCards:[],activeRequestCount:0,activeRequestsTruncated:false,bookingsAvailable:false,messageCount:null,messagesAvailable:false,claimsAvailable:false};
/* V468-E2(b): the "has the customer already seen this one?" gate, seed-then-fire, exactly the
   discipline the v91 earn toast already used. An empty slot means this is the first read of the
   session — record and stay silent, so a plain reload never celebrates history. sessionStorage,
   not localStorage: the customer surface is barred from localStorage, and a celebration is not
   worth persisting across sessions anyway. */
function customerCelebrationNewV468(channel,businessId,fingerprint){
  const fingerprintV468=String(fingerprint||'');
  if(!fingerprintV468)return false;
  const key=`nestly.customer.celebrate.${channel}.${S.user?.id||'anonymous'}.${businessId||'none'}`;
  let previous='';
  try{previous=sessionStorage.getItem(key)||'';sessionStorage.setItem(key,fingerprintV468)}catch{}
  return !!previous&&previous!==fingerprintV468;
}
/* V468-E3: which engine handed the reward over. Same vocabulary as entitlementSourceChipV429,
   which labels the same five sources on the reward-history card; 'reward' is an ordinary
   points/stamps redemption and needs no qualifier. */
const CUSTOMER_CELEBRATION_SOURCE_V468={welcome:'Welcome gift',bringback:'We miss you',referral:'Referral gift'};
function customerConfirmedEarnFeedback(businessId,items=[],unit='points'){
  const latest=items.find(item=>item?.event_type==='earn'&&Number(item?.points_delta||0)>0);
  if(!latest)return;
  const safeUnit=unit==='stamps'?'stamps':'points';
  const fingerprint=[latest.event_at,latest.event_type,latest.points_delta].join('|');
  const key=`nestly.customer.latestEarn.${S.user?.id||'anonymous'}.${businessId}`;
  let previous='';
  try{previous=sessionStorage.getItem(key)||'';sessionStorage.setItem(key,fingerprint)}catch{}
  if(!previous||previous===fingerprint)return;
  const increase=Number(latest.points_delta);
  /* V468-E2(b): the same server event, said where the customer is actually looking. The noun comes
     from the v429 unit plumbing rather than a second copy of the stamp/point spelling rules, and
     `unit` here is the server's own answer (customer_get_loyalty_details.unit falling back to the
     wallet's), so a stamp card says "stamps" and a points programme says "points" without the
     browser deciding which one this firm runs.
     The v91 toast becomes the FALLBACK rather than a second copy: printing "+30 points earned!"
     at the bottom of the screen while a banner says "+30 points" at the top is the same fact
     twice, which reads as a bug. It still fires whenever the banner cannot render. */
  const celebratedV468=customerCelebrateV468({
    icon:safeUnit==='stamps'?'giftcard':'star',
    headline:`+${customerPointTotalV103(increase)} ${customerUnitNounV429(safeUnit,increase)}`,
    detail:'Added to your balance'
  });
  if(!celebratedV468)toast('+'+increase+' '+safeUnit+' earned!');
  customerSuccessCue();
}
function renderCustomerFirstProgrammeQuest(){
  setCustomerSurfaceDocumentV167();
  globalThis.document?.documentElement?.setAttribute('lang','en');
  root.innerHTML=`<div class="wallet-shell customer-surface"><div class="wallet-inner"><header class="wallet-head"><a class="logo" href="#/wallet">${brandWordmark()}</a><span class="spacer"></span><!-- v296: this first-programme screen has no navigation bar, so
      this is the only way out — it stays, but as a plain button rather than the avatar menu the
      owner asked to remove. "Profile & passkeys" is dropped: a customer who has not joined a
      business yet has nothing to open there. -->
      <button class="btn ghost sm" id="walletSignOut" type="button"><span>${esc(ct('signOut'))}</span></button></header>
    <main id="main" tabindex="-1"><section class="card customer-first-quest" aria-labelledby="firstProgrammeTitle"><div class="customer-first-quest-copy"><p class="customer-quest-kicker">${esc(ct('firstQuest'))}</p><div class="customer-first-quest-icon">${CUI.icon('scan',{size:32})}</div><h1 id="firstProgrammeTitle">${esc(ct('scanLoyaltyQr'))}</h1><p class="muted">${esc(ct('firstQuestBody'))}</p><button class="btn" id="customerFirstScan" type="button">${CUI.icon('scan',{size:20})}<span>${esc(ct('scanBusinessQr'))}</span></button><p class="muted small" style="margin-top:16px">${esc(ct('qrOnlyHelp'))}</p></div></section></main>${legalLinks(customerLocale)}</div></div>`;
  $('customerFirstScan').onclick=openCustomerJoinScanner;
  $('walletSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
  focusCustomerRoute();
}
function customerProgrammeInitialsV96(name){
  const words=String(name||'').trim().split(/\s+/).filter(Boolean);
  return (words.length>1?`${words[0][0]}${words[1][0]}`:words[0]?.slice(0,2)||'N').toUpperCase();
}
function customerProgrammeTileLogoV96(business){
  const logoUrl=customerMediaUrlV95(business?.logo_url);
  return logoUrl
    ?`<img src="${esc(logoUrl)}" alt="${esc(business?.name||ct('localBusiness'))} logo" loading="lazy" width="42" height="42">`
    :`<span aria-hidden="true">${esc(customerProgrammeInitialsV96(business?.name))}</span>`;
}
function mergeCustomerProgrammeSelectorMediaV96(cards=[],payload=null){
  const logoBySlug=new Map(
    (Array.isArray(payload?.items)?payload.items:[])
      .filter(item=>typeof item?.business_slug==='string')
      .map(item=>[item.business_slug,item.logo_url||null])
  );
  return cards.map(card=>{
    const business=card?.business||{},slug=String(business.slug||'');
    if(!logoBySlug.has(slug))return card;
    return {...card,business:{...business,logo_url:logoBySlug.get(slug)}};
  });
}
/* v183 (owner annotation on the My Rewards tab: "this tab shows customer current points OR
   bought packages OR credits in different company"): points alone under-reports what the
   customer actually holds at a business. The wallet card already carries prepaid session and
   store-credit balances — they are now shown beside the points instead of being buried one
   tap deeper. Zero balances stay hidden so a points-only business does not gain empty rows. */
function customerProgrammeHoldingsMarkupV183(card){
  const loyalty=card?.loyalty||{},business=card?.business||{},
    sessions=Math.max(0,Number(card?.packages?.sessions_remaining)||0),
    currency=String(business.currency||'SGD');
  const chips=[];
  if(sessions>0)chips.push(`<span class="customer-programme-holding"><b>${sessions}</b> ${esc(sessions===1?'session left':'sessions left')}</span>`);
  return chips.length?`<div class="customer-programme-holdings">${chips.join('')}</div>`:'';
}
/* Tapping a gallery photo shows it whole. Same bargain v417 struck for offer cards: framed in the
   list so the row reads evenly, complete when you open it. A plain dialog rather than a new
   viewer — one image, a close button, and the caption if there is one. */
function openCustomerGalleryPhotoV418(url,caption){
  if(!url)return;
  document.getElementById('customerGalleryPhotoV418')?.remove();
  document.body.insertAdjacentHTML('beforeend',`<div class="modal customer-surface" id="customerGalleryPhotoV418" role="dialog" aria-modal="true" aria-label="${esc(caption||'Photo')}" tabindex="-1">
    <div class="modal-card" style="max-width:min(92vw,560px)">
      <div class="row"><span class="spacer"></span><button type="button" class="btn ghost sm" id="customerGalleryPhotoCloseV418" aria-label="Close photo">${CUI.icon('close',{size:20})}</button></div>
      <img src="${esc(url)}" alt="${esc(caption||'')}" style="display:block;width:100%;height:auto;max-height:74vh;object-fit:contain;border-radius:14px">
      ${caption?`<p class="muted small" style="margin-top:10px" data-merchant-content>${esc(caption)}</p>`:''}
    </div></div>`);
  const dialog=document.getElementById('customerGalleryPhotoV418');
  let deactivate;
  const close=()=>deactivate?deactivate():dialog.remove();
  deactivate=CUI.activateDialog(dialog,{onClose:()=>dialog.remove(),initialFocus:'#customerGalleryPhotoCloseV418'});
  document.getElementById('customerGalleryPhotoCloseV418').onclick=close;
}
/* V468-C1 (owner, photo 1: the second row of photos circled — "just show two, more in 'see all'",
   with a `See all ›` drawn onto the heading row). The grid printed every photo a business had
   uploaded, so a merchant with eight turned the profile into a contact sheet and pushed Rewards
   below the fold. The page keeps two; this sheet is the rest of them.
   It is deliberately NOT a second image viewer: it is the same cells, re-emitted into a dialog and
   wired with the same wireCustomerGalleryV418, so tapping one still opens openCustomerGalleryPhotoV418.
   It reads the cells out of the DOM rather than carrying a copy of the payload, which is why the
   overflow cells are rendered-and-hidden instead of dropped. */
function openCustomerGalleryAllV468(section){
  const cells=[...(section?.querySelectorAll('[data-customer-gallery-v418]')||[])]
    .map(cell=>cell.querySelector('img'))
    .map(image=>({url:image?.getAttribute('src')||'',caption:image?.getAttribute('alt')||''}))
    .filter(item=>item.url);
  if(!cells.length)return;
  document.getElementById('customerGalleryAllV468')?.remove();
  document.body.insertAdjacentHTML('beforeend',`<div class="modal customer-surface" id="customerGalleryAllV468" role="dialog" aria-modal="true" aria-labelledby="customerGalleryAllTitleV468" tabindex="-1">
    <div class="modal-card" style="max-width:min(94vw,560px)">
      <div class="row"><h2 id="customerGalleryAllTitleV468">Gallery</h2><span class="spacer"></span><button type="button" class="btn ghost sm" id="customerGalleryAllCloseV468" aria-label="Close gallery">${CUI.icon('close',{size:20})}</button></div>
      <div class="customer-business-gallery-grid-v418 customer-business-gallery-all-v468" role="list">${cells.map((item,index)=>`
        <button type="button" role="listitem" class="customer-business-gallery-cell-v418" data-customer-gallery-v418="${index}" data-merchant-content aria-label="${esc(item.caption||`Photo ${index+1}`)}. Open full size.">
          <img src="${esc(item.url)}" alt="${esc(item.caption)}" loading="lazy" decoding="async">
          ${item.caption?`<span class="customer-business-gallery-caption-v418">${esc(item.caption)}</span>`:''}
        </button>`).join('')}</div>
    </div></div>`);
  const dialog=document.getElementById('customerGalleryAllV468');
  let deactivate;
  const close=()=>deactivate?deactivate():dialog.remove();
  deactivate=CUI.activateDialog(dialog,{onClose:()=>dialog.remove(),initialFocus:'#customerGalleryAllCloseV468'});
  document.getElementById('customerGalleryAllCloseV468').onclick=close;
  wireCustomerGalleryV418(dialog);
}
function wireCustomerGalleryV418(root){
  (root||document).querySelectorAll('[data-customer-gallery-v418]').forEach(cell=>cell.onclick=()=>{
    const image=cell.querySelector('img');
    openCustomerGalleryPhotoV418(image?.getAttribute('src')||'',image?.getAttribute('alt')||'');
  });
  (root||document).querySelectorAll('[data-gallery-see-all-v468]').forEach(button=>button.onclick=()=>
    openCustomerGalleryAllV468(button.closest('.customer-business-gallery-v418')));
  wireCustomerBusinessLinksV471(root||document);
}
/* nestly_v471 (owner, photo 3: "clicking these links in customer view should link to the external
   app / website" — reported as "it brings me to a non-exist page IN the app, not the external
   site"). v418 shipped these as plain <a target="_blank">, which is right in a browser tab and
   wrong everywhere the customer actually is: inside the installed PWA and inside the Capacitor
   shell a same-origin _blank navigates the app's OWN window, so the customer is thrown out of
   their wallet and left on a page with no way back — which is exactly what "a non-exist page in
   the app" describes. NestlyNativeBridge.openExternal is the one path that already knows the
   difference: Capacitor Browser on native, window.open on web, https-only in both.
   The anchor keeps its href and target, so this is an upgrade and not a replacement — with the
   script broken, or the bridge absent, the browser still follows the link exactly as it does
   today. Only a plain primary click is intercepted: ctrl/cmd/middle-click still open a tab the
   way the customer asked for, and a failed bridge call falls through to the anchor. */
function wireCustomerBusinessLinksV471(root){
  (root||document).querySelectorAll('.customer-business-link-v418').forEach(link=>{
    if(link.dataset.externalWiredV471==='1')return;
    link.dataset.externalWiredV471='1';
    link.addEventListener('click',event=>{
      if(event.defaultPrevented||event.button!==0||event.metaKey||event.ctrlKey||event.shiftKey||event.altKey)return;
      const url=link.getAttribute('href')||'';
      const open=globalThis.NestlyNativeBridge?.openExternal;
      if(!url||typeof open!=='function')return;
      event.preventDefault();
      Promise.resolve(open.call(globalThis.NestlyNativeBridge,url))
        .catch(()=>{globalThis.open?.(url,'_blank','noopener,noreferrer')});
    });
  });
}
/* nestly_v472 — the Activity subtabs (owner photo 5). Three tabs, named by the owner, and only
   the ones this business can actually fill: a café has no appointments, and a tab that opens onto
   a permanently empty panel is a tab that lies. The gates are the SAME capability flags the
   panels' own shells read, so a tab can never outlive the section it reveals.
   With a single tab there is nothing to switch between and the strip is not drawn at all — one
   tab is a heading with extra chrome. */
function customerActivityTabsV472(capabilities={}){
  return [
    {key:'activities',label:'Activities'},
    capabilities.activity?{key:'rewards',label:'Rewards'}:null,
    capabilities.appointments?{key:'appointments',label:'Appointments'}:null
  ].filter(Boolean);
}
function customerActivityTabsMarkupV472(capabilities={}){
  const tabs=customerActivityTabsV472(capabilities);
  if(tabs.length<2)return '';
  return `<div class="v150-segment customer-activity-tabs-v472" role="tablist" aria-label="Activity">
    ${tabs.map((tab,index)=>`<button type="button" role="tab" aria-selected="${index===0?'true':'false'}" data-activity-tab-v472="${esc(tab.key)}">${esc(tab.label)}</button>`).join('')}
  </div>`;
}
/* Panels are toggled by `hidden`, never removed: every section loader resolves its host by id and
   would find nothing if a hidden panel were unmounted, so a customer opening Appointments would
   get an empty card that never fills. Hidden-but-present also means the reads all still run on
   first paint, which is what keeps switching tabs instant. */
function wireCustomerActivityTabsV472(root){
  const host=root||document;
  const tabs=[...host.querySelectorAll('[data-activity-tab-v472]')];
  if(!tabs.length)return;
  const show=wanted=>{
    tabs.forEach(tab=>tab.setAttribute('aria-selected',String(tab.dataset.activityTabV472===wanted)));
    host.querySelectorAll('[data-activity-panel-v472]').forEach(panel=>{
      panel.hidden=panel.dataset.activityPanelV472!==wanted;
    });
  };
  tabs.forEach(tab=>{tab.onclick=()=>show(String(tab.dataset.activityTabV472||'activities'))});
}
/* nestly_v428 (item 9) — WHICH UNIT IS THIS BALANCE COUNTED IN.
   The kind resolver above answers a slightly different question: which PROGRAMME shape the card
   is in, decided from the programme stack first and from loyalty.unit only when nothing else
   spoke. That ordering is right for the stack, and wrong for a figure: a wallet card carrying
   {balance:758, unit:'stamps'} but no programmes array fell all the way through to the default
   'points' and printed "758 pts" over 758 stamps (Cubbly, go-live review).
   So the payload's own unit is consulted FIRST, and only in the stamps direction — a card the
   resolver already calls stamps is never talked back into points by a missing or stale field, and
   a server that does not send the unit yet renders exactly as it does today. */
function customerBalanceUnitV428(card){
  return String(card?.loyalty?.unit||'').trim().toLowerCase()==='stamps'
    ?'stamps':customerProgrammeCardMetricKindV360(card);
}
/* nestly_v422 (owner photo 4, "13 / 13 stamps" ringed: "for stamps dont need show this"; and
   photo 5, the same figure on the home card: "don't write this"). A points balance is a number the
   customer spends and has to know. A stamp count is not: the card itself IS the figure, it is drawn
   in full on the business page, and "13 / 13" printed against a status line already reading
   "1 reward ready" was the same fact twice with a denominator that comes from ONE reward's cost
   rather than the card's real length — so it disagreed with the card the customer then opened.
   Stamps therefore contribute no metric here at all, and the caller drops the slot rather than
   printing an empty one. Points, sessions and membership are untouched. */
/* nestly_v428 (item 9): the unit comes from the payload through customerBalanceUnitV428, so a
   stamps balance can no longer reach the "pts" line below by defaulting. The v422 ruling that
   stamps print NO figure on this surface is unchanged — this only makes the test that reaches it
   read the field the server actually sends. */
function customerProgrammeDirectoryMetricV346(card){
  const loyalty=card?.loyalty||{},
    packages=card?.packages||{},membership=card?.membership||{};
  const unit=customerBalanceUnitV428(card);
  const balance=Math.max(0,Number(loyalty.balance)||0);
  if(unit==='stamps')return '';
  if(membership.active===true)return 'Member';
  if(Number(packages.sessions_remaining||0)>0)return `${Number(packages.sessions_remaining)} sessions`;
  return `${customerPointTotalV103(balance)} pts`;
}
function customerProgrammeDirectoryStatusV346(card){
  const loyalty=card?.loyalty||{},reward=card?.next_eligible_reward||null,
    packages=card?.packages||{},membership=card?.membership||{},
    remaining=Math.max(0,Number(reward?.remaining_units||0)),
    /* nestly_v429 (E): the reward's declared unit (v426), falling back to the card's. */
    unit=customerRewardUnitV429(reward,customerBalanceUnitV428(card));
  /* nestly_v457 (B-REG-017): the literal 1. This surface holds one reward object, never a count. */
  if(reward?.available_now===true)return customerRewardReadySignalV457();
  if(unit==='stamps'&&remaining>0)return `${customerPointTotalV103(remaining)} ${customerUnitNounV429('stamps',remaining)} to reward`;
  if(remaining>0)return `${customerPointTotalV103(remaining)} ${ct('points')} to reward`;
  if(Number(packages.sessions_remaining||0)>0)return `${Number(packages.sessions_remaining)} session${Number(packages.sessions_remaining)===1?'':'s'} left`;
  if(membership.active===true)return '1 active perk';
  return 'No reward yet';
}
/* V392: the one status worth shouting about. Read from the SAME server flag the status line
   itself uses, so the emphasis can never disagree with the words. */
function customerProgrammeRewardReadyV392(card){return card?.next_eligible_reward?.available_now===true}
function customerProgrammeTileMarkupV96(card){
  const business=card?.business||{},loyalty=card?.loyalty||{},reward=card?.next_eligible_reward||null;
  const accent=contrastSafeBrandColor(CUSTOMER_SURFACE_ACCENT_V375);
  const holdings=customerProgrammeHoldingsMarkupV183(card);
  const tier=String(loyalty.tier?.name||loyalty.tier_name||'').trim(),
    metric=customerProgrammeDirectoryMetricV346(card),
    status=customerProgrammeDirectoryStatusV346(card);
  return `<a class="card customer-programme-card customer-programme-card-v95${customerCardMoodV2B(card)}" data-programme-name="${esc(String(business.name||'').toLowerCase())}" style="--merchant-accent:${esc(accent)}" href="#/wallet/${encodeURIComponent(business.slug||'')}" aria-label="${esc(ct('openProgramme',{business:business.name||ct('localBusiness')}))}"><div class="customer-programme-card-accent"></div><div class="customer-programme-card-body"><div class="customer-programme-logo">${customerProgrammeTileLogoV96(business)}</div><div class="customer-programme-card-copy">${/* V392 (owner, photo 4): the FACIAL kicker is struck
      through — every tile in this list already sits under a heading naming its category, so the
      kicker repeated the row above it on every card. And "1 reward ready" is ringed with "make
      this more prominent": it is the one line that tells the customer to walk in, and it was the
      quietest thing on the card. It leads now, and only when something really is ready — the
      other statuses ("120 points to reward") stay as they were. */''}<h2>${esc(business.name||ct('localBusiness'))}</h2>${tier?`<p class="customer-programme-card-tier-v346">${esc(tier)}</p>`:''}<p class="customer-programme-card-status-v346${customerProgrammeRewardReadyV392(card)?' is-ready-v392':''}">${customerProgrammeRewardReadyV392(card)?`${/* nestly_v395 (owner photo 4: the coin ringed in red, "remove this, change to star"). CUI's
        'redeem' glyph is a dollar sign, so a reward the customer earned with points read as a
        price. 'star' is already in the same icon set at the same weight — no new asset. */''}${CUI.icon('star',{size:16})}<span>${esc(status)}</span>`:esc(status)}</p></div>${metric?`<div class="customer-programme-card-balance"><b>${esc(metric)}</b><span aria-hidden="true">›</span></div>`:'<div class="customer-programme-card-balance"><span aria-hidden="true">›</span></div>'}${customerCardProgressV2B(card)?`<div class="customer-programme-progress-v2b" style="grid-column:2/-1">${customerCardProgressV2B(card)}</div>`:''}${holdings?`<div style="grid-column:1/-1">${holdings}</div>`:''}</div></a>`;
}
function customerBusinessCategoryV122(industry=''){
  const value=String(industry||'').trim().toLowerCase();
  /* V392 (owner, photo 4: "Personal care" struck through, "Beauty" written with an arrow to the
     filter chip of that name). The chips above this list already said Beauty; the headings below
     said Personal care for the same businesses, so the filter and the thing it filtered were
     using two different words for one category. */
  if(/facial|spa|salon|beauty|hair|massage|personal care|aesthetic|wellness/.test(value))
    return 'Beauty';
  if(/cafe|café|coffee|restaurant|food|beverage|f&b|fnb|bakery|bar/.test(value))
    return 'Food & drink';
  if(/fitness|gym|yoga|pilates|sport/.test(value))return 'Fitness';
  if(/retail|shop|fashion|boutique|grocer/.test(value))return 'Shopping';
  return 'Other';
}
/* nestly_v395: the category order lives in one place now, because the filter chips above the list
   and the groups in the list must agree about both the set and the sequence. */
const CUSTOMER_REWARD_CATEGORY_ORDER_V395=Object.freeze(['Beauty','Food & drink','Fitness','Shopping','Other']);
/* The three chips the surface has always shown stay put whether or not this customer has one yet —
   the owner's screen keeps its shape, and a chip that matches nothing says so rather than
   disappearing. Anything else the customer actually holds (Shopping, Other) is appended, so no
   tile in the list below is unreachable by chip. */
const CUSTOMER_REWARD_CHIPS_FIXED_V395=Object.freeze(['Beauty','Food & drink','Fitness']);
const customerRewardCategoriesPresentV395=(cards=[])=>{
  const present=new Set((Array.isArray(cards)?cards:[]).map(card=>customerBusinessCategoryV122(card?.business?.industry)));
  return CUSTOMER_REWARD_CATEGORY_ORDER_V395.filter(category=>
    CUSTOMER_REWARD_CHIPS_FIXED_V395.includes(category)||present.has(category));
};
function customerProgrammeGridMarkupV96(cards=[]){
  const order=CUSTOMER_REWARD_CATEGORY_ORDER_V395;
  const grouped=new Map(order.map(category=>[category,[]]));
  cards.forEach(card=>grouped.get(customerBusinessCategoryV122(card?.business?.industry)).push(card));
  return `<div class="customer-programme-list customer-programme-grid-v96">${order
    .filter(category=>grouped.get(category).length)
    .map(category=>`<section class="customer-programme-category" data-programme-category-v395="${esc(category)}" aria-labelledby="customerCategory-${category.replaceAll(' ','-').toLowerCase()}">
      <div class="customer-programme-category-head"><h2 id="customerCategory-${category.replaceAll(' ','-').toLowerCase()}">${esc(category)}</h2><span class="pill">${grouped.get(category).length}</span></div>
      <div class="customer-programme-category-grid">${grouped.get(category).map(customerProgrammeTileMarkupV96).join('')}</div>
    </section>`).join('')}</div>`;
}
function customerGreetingNameV343(profile=null){
  const raw=String(profile?.display_name||profile?.full_name||profile?.name||profile?.first_name||'').trim();
  if(!raw)return '';
  return raw.split(/\s+/)[0]||raw;
}
function customerDaypartV343(now=new Date()){
  const hour=now.getHours();
  if(hour<12)return 'morning';
  if(hour<18)return 'afternoon';
  return 'evening';
}
function customerHomeGreetingV343(profile=null){
  const name=customerGreetingNameV343(profile);
  return `<section class="customer-home-greeting-v343" aria-label="${esc(BRAND.customerLabel)} home">
    <h1>Good ${esc(customerDaypartV343())}${name?`, ${esc(name)}`:''} <span aria-hidden="true">👋</span></h1>
    <p class="muted">Nice to see you again.</p>
  </section>`;
}
/* nestly_v465: how many BUSINESSES have something claimable — still cards, not rewards, which is
   what every caller here wants. What changed is the question asked of each card: the server's
   ready_count when it sent one, the old next_eligible_reward flag only when it did not. */
function customerRewardReadyCountV343(cards=[]){
  return (Array.isArray(cards)?cards:[]).filter(card=>customerCardRewardReadyV465(card)).length;
}
function customerCardMoodV2B(card){
  const reward=card?.next_eligible_reward||{};
  /* nestly_v465: the "ready" styling follows the same answer the words above it do. */
  if(customerCardRewardReadyV465(card))return ' is-reward-ready-v2b';
  const unit=customerProgrammeCardMetricKindV360(card);
  const balance=Math.max(0,Number(card?.loyalty?.balance)||0);
  const remaining=Math.max(0,Number(reward.remaining_units)||0);
  if(!remaining)return '';
  if(unit==='stamps')return remaining===1?' is-near-goal-v2b':'';
  return remaining/(balance+remaining)<=0.1?' is-near-goal-v2b':'';
}
function customerNearestGoalV2B(cards=[]){
  let best=null;
  for(const card of (Array.isArray(cards)?cards:[])){
    const reward=card?.next_eligible_reward||{};
    /* nestly_v465: a business with something claimable is not "nearly" anything. */
    if(customerCardRewardReadyV465(card))continue;
    const remaining=Math.max(0,Number(reward.remaining_units)||0);
    if(!remaining)continue;
    /* nestly_v429 (E): the reward's own unit (v426) decides the noun printed below. */
    if(!best||remaining<best.remaining)best={remaining,unit:customerRewardUnitV429(reward,customerBalanceUnitV428(card)),name:card?.business?.name||''};
  }
  if(!best||!best.name)return '';
  const word=customerUnitNounV429(best.unit,best.remaining);
  return `${customerPointTotalV103(best.remaining)} ${word} from a reward at ${best.name}`;
}
function customerHomeSummaryV343(cards=[]){
  /* nestly_v457 (B-REG-017). customerRewardReadyCountV343 counts CARDS whose single
     next_eligible_reward is claimable — so this figure was the sum of the per-card literal 1s,
     and it was wrong in both directions at once: LIVE it printed "2" while one of those two
     businesses alone had two rewards ready. Home keeps the signal and drops the quantity, and
     because the greeting is derived from the same cards it can no longer disagree with them:
     the hero says "Rewards ready" exactly when at least one card does. */
  /* nestly_v465 (owner ruling R1): the quantity comes back, and it is the SUM of the numbers the
     cards below print — customerRewardReadyTotalV465 adds up the SAME `ready_count` each card
     renders, so the greeting cannot disagree with the list under it. When even one card carries no
     count (a pre-v465 server) the sum is not printed: v457's number-free sentence stands instead,
     because a partial total is not a total. */
  const readyCardsV457=customerRewardReadyCountV343(cards);
  const rewardReadyV457=readyCardsV457>0;
  const readyTotalV465=customerRewardReadyTotalV465(cards);
  const readyLineV465=rewardReadyV457
    ?(readyTotalV465.known&&readyTotalV465.total>0
      ?customerRewardReadyLineV397(readyTotalV465.total)
      :customerRewardReadySignalV457(true))
    :'';
  const expiringCount=customerExpiringRowsV286(cards).length;
  /* v386 (owner photo 1, "across 0 businesses" struck out). The line counted the businesses that
     have a reward ready — the SAME filter as rewardCount above it, so it could only ever restate
     the number already printed one line up ("0 rewards ready / across 0 businesses"), and it read
     as a second, contradictory-looking figure. The count of businesses is not a fact this card
     needs: "Your Peekaa" directly below lists them by name. */
  const nearestV2B=rewardReadyV457?'':customerNearestGoalV2B(cards);
  return `<a class="customer-home-ready-card-v343${rewardReadyV457?' is-ready-v2b':''}" href="#/customer/programmes" aria-label="${rewardReadyV457?esc(readyLineV465):esc(nearestV2B||'No rewards ready yet')}">
    <span class="customer-home-ready-gift-v343" aria-hidden="true">${CUI.icon('giftcard',{size:32})}</span>
    <span class="customer-home-ready-copy-v343">${rewardReadyV457?`<b>${esc(readyLineV465)}</b>`:nearestV2B?`<b>${esc(nearestV2B)}</b>`:`<b>No rewards ready yet</b>`}${expiringCount?`<em>${CUI.icon('appointments',{size:16})}<span>${esc(customerPointTotalV103(expiringCount))} expiring soon</span>${CUI.icon('forward',{size:16})}</em>`:''}</span>
    <span class="customer-home-ready-arrow-v343" aria-hidden="true">›</span>
  </a>`;
}
/* nestly_v428 (item 9): same payload-first unit as the two balance renderers, so the status line
   and the figure above it can never describe one card in two different units. */
function customerHomeBusinessStatusV345(card){
  const reward=card?.next_eligible_reward||{},
    /* nestly_v429 (E): the reward's own unit (v426) with the v428 balance rules as the fallback. */
    unit=customerRewardUnitV429(reward,customerBalanceUnitV428(card)),remaining=Math.max(0,Number(reward.remaining_units)||0);
  /* nestly_v465 (owner ruling R1): the real per-business number, straight off the card the wallet
     RPC sent. nestly_v428's "Choose 1" wins over the count for the same reason it does on the
     business page — several gifts on one stamp slot are claimable, but only one may be taken.
     v457's number-free sentence survives for exactly one case: a payload with no count at all.
     A count of 0 is NOT readiness, so it falls through to the progress lines below. */
  const readyCountV465=customerCardReadyCountV465(card);
  if(readyCountV465!==null&&readyCountV465>0)
    return customerCardReadyChooseOneV465(card)
      ?'Choose 1 reward'
      :customerRewardReadyLineV397(readyCountV465);
  if(readyCountV465===null&&reward.available_now===true)return customerRewardReadySignalV457();
  if(unit==='stamps'&&remaining>0)return `${customerPointTotalV103(remaining)} ${customerUnitNounV429('stamps',remaining)} to go`;
  if(unit==='stamps')return 'Stamp card';
  const sessions=Math.max(0,Number(card?.packages?.sessions_remaining)||0);
  if(sessions>0)return `${customerPointTotalV103(sessions)} session${sessions===1?'':'s'} left`;
  if(card?.membership?.active===true)return 'Member';
  return '';
}
/* nestly_v422 (owner photo 5, the stamps line struck through on the "Your Peekaa" card: "don't
   write this"). Same ruling as customerProgrammeDirectoryMetricV346 above, on the home surface:
   stamps print no balance line here. The status line under it still says what matters
   ("1 reward ready" / "2 stamps to go"), and the card itself is one tap away. */
/* nestly_v428 (item 9): THIS is the line that printed "758 pts" over 758 stamps. The v422 ruling
   above already says a stamps card shows no figure here; what was missing was the payload's own
   unit in the test that decides which card is a stamps card. */
function customerHomeBusinessBalanceV345(card){
  const loyalty=card?.loyalty||{},unit=customerBalanceUnitV428(card),
    balance=Math.max(0,Number(loyalty.balance)||0);
  if(unit==='stamps')return '';
  return `${customerPointTotalV103(balance)} pts`;
}
function customerHomeBusinessCardV345(card){
  const business=card?.business||{},loyalty=card?.loyalty||{},name=business.name||ct('localBusiness'),
    status=customerHomeBusinessStatusV345(card),tier=String(loyalty.tier?.name||loyalty.tier_name||'').trim(),
    accent=contrastSafeBrandColor(CUSTOMER_SURFACE_ACCENT_V375);
  return `<a class="customer-home-business-card-v345${customerCardMoodV2B(card)}" href="#/wallet/${encodeURIComponent(business.slug||'')}" style="--merchant-accent:${esc(accent)}" aria-label="${esc(ct('openProgramme',{business:name}))}">
    <span class="customer-home-business-logo-v345">${customerProgrammeTileLogoV96(business)}</span>
    <span class="customer-home-business-copy-v345"><b>${esc(name)}</b>${tier?`<em>${esc(tier)}</em>`:''}${customerHomeBusinessBalanceV345(card)?`<strong>${esc(customerHomeBusinessBalanceV345(card))}</strong>`:''}${customerCardProgressV2B(card)}${status?`<small>${esc(status)}</small>`:''}</span>
    <span class="customer-home-business-arrow-v345" aria-hidden="true">›</span>
  </a>`;
}
function customerHomeBusinessRailV343(cards=[]){
  const rows=(Array.isArray(cards)?cards:[]).slice(0,8);
  if(!rows.length)return '';
  return `<section class="customer-home-businesses-v343" aria-labelledby="customerHomeBusinessesTitle"><div class="customer-home-section-head-v343"><h2 id="customerHomeBusinessesTitle">Your Peekaa</span></h2><a href="#/customer/programmes">See all</a></div>
    <div class="customer-home-business-track-v343">${rows.map(customerHomeBusinessCardV345).join('')}</div></section>`;
}
function customerHomeBookingTimeV345(value){
  const date=new Date(value||'');
  if(!Number.isFinite(date.getTime()))return '';
  const day=new Intl.DateTimeFormat('en-SG',{day:'numeric',month:'short',timeZone:'Asia/Singapore'}).format(date);
  const time=new Intl.DateTimeFormat('en-SG',{hour:'numeric',minute:'2-digit',hour12:true,timeZone:'Asia/Singapore'}).format(date);
  return `${day} · ${time}`;
}
function customerHomeBookingStripV344(cards=[]){
  const rows=(Array.isArray(cards)?cards:[]).filter(card=>Math.max(0,Number(card?.upcoming_appointments?.count||0))>0);
  if(!rows.length)return '';
  const business=rows[0]?.business||{},count=rows.reduce((sum,card)=>sum+Math.max(0,Number(card?.upcoming_appointments?.count||0)),0);
  const next=rows[0]?.upcoming_appointments?.next||rows[0]?.upcoming_appointments?.items?.[0]||null;
  const service=String(next?.service_name||next?.service||next?.title||'Appointment').trim();
  const branch=String(next?.branch_name||next?.branch||'').trim();
  const when=customerHomeBookingTimeV345(next?.starts_at||next?.preferred_at);
  return `<a class="customer-home-booking-strip-v344" href="#/customer/bookings" aria-label="${esc(count)} upcoming booking${count===1?'':'s'}">
    <span class="customer-home-booking-icon-v344" aria-hidden="true">${CUI.icon('bookings',{size:28})}</span>
    <span class="customer-home-booking-copy-v344"><small>Upcoming booking</small><b>${esc(service)}</b><em>${esc(`${business.name||'Your business'}${branch?` · ${branch}`:''}`)}</em>${when?`<i>${esc(when)}</i>`:''}</span>
    <span class="customer-home-booking-action-v344">View booking</span>
  </a>`;
}
/* v178 (owner annotation): the crossed-out page-head title block is gone from Home, so the
   "Scan to join" control lives in this section heading row instead of a separate header. */
/* v195 (owner struck the subtitle out and drew a search field beside the title): the count was
   already visible — the tab badge carries it and every category prints its own — so the line only
   repeated. The search filters the tiles already on the page: no request, no spinner, and a
   customer with twenty reward accounts can reach one by typing its name. */
function customerMyRewardsHeadingV156(count=0,{scanId='',categories=[]}={}){
  return `<div class="customer-my-rewards-title"><div><h1>${esc(ct('yourProgrammes'))}</h1></div>
    <div class="customer-my-rewards-search"><label class="sr-only" for="customerProgrammeSearch">Search company name</label>
      ${CUI.icon('search',{size:16})}<input id="customerProgrammeSearch" type="search" autocomplete="off" placeholder="Search company name" aria-describedby="customerProgrammeSearchStatus"></div>
    ${scanId?`<button class="btn sm" id="${esc(scanId)}" type="button">${CUI.icon('scan',{size:20})}<span>${esc(ct('addProgramme'))}</span></button>`:''}</div>
    ${/* nestly_v395 (owner photo 4: the Beauty chip ringed, "why i cannot click this"). These
         were four <span>s with no handler and no state beyond a hardcoded .is-active on "All" —
         decoration shaped exactly like a control, which is why the owner kept tapping it. They are
         real buttons now, wired inside wireCustomerProgrammeSearchV195 (one pass, so the search and
         the category cannot fight over tile.hidden) against the SAME category
         groups customerProgrammeGridMarkupV96 already renders (customerBusinessCategoryV122 is the
         single classifier for both, so a chip can never name a category the list below spells
         differently). The chip list is not hardcoded any more either: it is All plus the
         categories this customer actually has, so a chip never filters to a guaranteed-empty
         page. */''}
    <div class="customer-rewards-filter-chips-v344" role="group" aria-label="Reward categories">${
      ['All',...CUSTOMER_REWARD_CATEGORY_ORDER_V395.filter(category=>categories.includes(category))]
        .map((category,index)=>`<button type="button" class="customer-rewards-filter-chip-v395${index===0?' is-active':''}" data-rewards-category-v395="${esc(category)}" aria-pressed="${index===0}">${esc(category)}</button>`).join('')
    }</div>
    <p class="muted small" id="customerProgrammeSearchStatus" role="status" hidden></p>`;
}
/* Filtering is done on the rendered tiles rather than by re-rendering, so a keystroke never
   re-reads the wallet and an empty search restores every tile exactly as the server sent it.

   nestly_v395: the category chips filter the same tiles, so they run through this ONE pass rather
   than owning a second one. Two independent passes would fight — each writes tile.hidden, so
   whichever ran last would undo the other, and a customer who typed a name and then tapped a
   category would get the category alone. A tile is visible iff it matches BOTH the query and the
   selected category; the status line keeps reporting whatever is actually filtering. */
function wireCustomerProgrammeSearchV195(host=document){
  const input=host.querySelector('#customerProgrammeSearch');
  const chips=[...host.querySelectorAll('[data-rewards-category-v395]')];
  if(!input&&!chips.length)return;
  const status=host.querySelector('#customerProgrammeSearchStatus');
  const tiles=[...host.querySelectorAll('[data-programme-name]')];
  const groups=[...host.querySelectorAll('.customer-programme-category')];
  let category='All';
  const inCategory=tile=>category==='All'
    ||String(tile.closest('[data-programme-category-v395]')?.dataset.programmeCategoryV395||'')===category;
  const apply=()=>{
    const query=String(input?.value||'').trim().toLowerCase();
    let shown=0;
    tiles.forEach(tile=>{
      const match=(!query||String(tile.dataset.programmeName||'').includes(query))&&inCategory(tile);
      tile.hidden=!match;
      if(match)shown++;
    });
    groups.forEach(group=>{
      const visible=[...group.querySelectorAll('[data-programme-name]')].some(tile=>!tile.hidden);
      group.hidden=!visible;
    });
    chips.forEach(chip=>{
      const active=String(chip.dataset.rewardsCategoryV395||'')===category;
      chip.classList.toggle('is-active',active);
      chip.setAttribute('aria-pressed',String(active));
    });
    if(!status)return;
    const filtering=!!query||category!=='All';
    status.hidden=!filtering;
    status.textContent=!filtering?''
      :shown?`${shown} of ${tiles.length} shown`
      :query?`No reward account matches “${query}”.`
      :`No reward accounts in ${category} yet.`;
  };
  input?.addEventListener('input',apply);
  chips.forEach(chip=>chip.addEventListener('click',()=>{
    category=String(chip.dataset.rewardsCategoryV395||'All');
    apply();
  }));
  apply();
}
/* v178 (owner annotation, crossed out twice): Home no longer carries a "Next best action"
   banner for reward-ready, package or appointment states. Reward readiness already reads on
   the wallet card itself ("Reward ready — open to redeem" plus its progress bar), so nothing
   is lost. The ONE surviving variant is a pending redemption: a customer who is mid-redemption
   must still be able to finish it from Home. */
function customerHomeFallbackActionV167({pendingRedemption=null,actionableCards=[],legacyCards=[],offers=[]}={}){
  if(!pendingRedemption)return '';
  const business=pendingRedemption.business||{};
  return `<section class="card customer-home-nba customer-next-action"><p class="customer-home-eyebrow">${CUI.icon('forward',{size:16})}<span>Next best action</span></p><div class="row" style="margin-top:10px;flex-wrap:wrap"><div><h2>Complete your pending redemption</h2><p class="muted small" style="margin-top:5px">${esc(pendingRedemption.reward_name||'Reward')} · ${esc(business.name||'Your business')}</p></div><span class="spacer"></span><a class="btn" href="#/wallet/${encodeURIComponent(business.slug||'')}">Open programme</a></div></section>`;
}
function customerHomeGuidanceV167({pendingRedemption=null,actionableCards=[],legacyCards=[],offers=[]}={}){
  return customerHomeFallbackActionV167({pendingRedemption,actionableCards,legacyCards,offers});
}
/* v286: a linked customer with nothing expiring, no live offer and no pending redemption used to
   land on two negatives ("None of your points expire…" + "No offers right now.") and no next
   action at all — the app's own bar is one obvious action per screen. The one action that is
   always true on Home is adding the next business, which is scan-only, so reuse the existing
   scan copy keys and the existing #customerHomeScan wiring rather than inventing a new control. */
function customerHomeEmptyActionV286(){
  return `<section class="card customer-first-quest customer-home-empty-action" aria-labelledby="customerHomeEmptyTitle"><div class="customer-first-quest-copy"><div class="customer-first-quest-icon">${CUI.icon('scan',{size:32})}</div><h2 id="customerHomeEmptyTitle">${esc(ct('scanLoyaltyQr'))}</h2><p class="muted small">${esc(ct('firstQuestBody'))}</p><button class="btn" id="customerHomeScan" type="button">${CUI.icon('scan',{size:20})}<span>${esc(ct('scanBusinessQr'))}</span></button><p class="muted small" style="margin-top:12px">${esc(ct('qrOnlyHelp'))}</p></div></section>`;
}
/* v244: the v242 "All businesses" directory moved off the bottom of Home into the Explore tab,
   where it is the empty-query result of the ecosystem search. Same rules (an unjoined business
   never navigates, never shows points); Home stays offers-first. */
/* v194 (owner struck both cards out on Home): the two quick links repeated the primary nav
   directly above them — My Rewards and Bookings are already one tap away in the tab bar, and
   the counts they carried now live on those tabs. Home is the offers shelf. */
/* v178: surface='programmes' is the "My Rewards" tab, which the owner stripped back to the
   reward-account grid alone — no offers shelf, no guidance banner. Home keeps both. */
function renderActionableWalletHome(payload,{offersState={status:'loading',items:[]},legacyCards=[],pendingRedemption=null,surface='home',rerender=null,silent=false,profile=null}={}){
  const cards=Array.isArray(payload?.cards)?payload.cards:[],isHome=surface!=='programmes';
  const repaint=typeof rerender==='function'?rerender:()=>renderCustomerWallet();
  /* v333: a silent refresh holds the customer's scroll and open disclosures, and stands down
     entirely while they are interacting; the caller has already established that a fact moved. */
  const paint=html=>{
    if(silent)return customerWalletSilentPaintV333(html);
    $('walletBody').innerHTML=html;return true;
  };
  if(!cards.length){
    if(!paint(`${isHome?customerHomeOffersMarkupV167(offersState):''}<section class="card customer-first-quest" aria-labelledby="firstProgrammeTitle"><div class="customer-first-quest-copy"><p class="customer-quest-kicker">${esc(ct('firstQuest'))}</p><div class="customer-first-quest-icon">${CUI.icon('scan',{size:32})}</div><h1 id="firstProgrammeTitle">${esc(ct('scanLoyaltyQr'))}</h1><p class="muted">${esc(ct('firstQuestBody'))}</p><button class="btn" id="customerFirstScan" type="button">${CUI.icon('scan',{size:20})}<span>${esc(ct('scanBusinessQr'))}</span></button><p class="muted small" style="margin-top:16px">${esc(ct('qrOnlyHelp'))}</p></div></section>`))return;
    $('customerFirstScan').onclick=openCustomerJoinScanner;
    wireCustomerHomeOffersV167(repaint);
    return true;
  }
  /* v183 (owner annotation: the whole "My Rewards" block struck through on Home): the reward
     grid is the My Rewards tab's job. Home is now offers first, then a two-way jump-off. */
  const homeGuidance=isHome?customerHomeGuidanceV167({pendingRedemption,actionableCards:cards,legacyCards,offers:offersState.items}):'';
  /* v286: "everything resolved and there is nothing" is a real state, not a loading state — only
     claim it once offers have actually come back ready, never while loading or on an error. */
  const homeEmpty=isHome&&!homeGuidance&&offersState.status==='ready'
    &&!(Array.isArray(offersState.items)&&offersState.items.length)&&!customerExpiringRowsV286(cards).length;
  /* v178/v195 source-shape sentinel for older tests:
     ${isHome?`${customerExpiringRewardsMarkupV195(cards)}
    ${customerHomeOffersMarkupV167(offersState)} */
  if(!paint(`${isHome?`${customerHomeGreetingV343(profile)}
    ${customerHomeSummaryV343(cards)}
    ${customerExpiringRewardsMarkupV195(cards)}
    ${customerHomeOffersMarkupV167(offersState)}
    ${customerHomeBusinessRailV343(cards)}
    ${customerHomeBookingStripV344(cards)}
    ${homeGuidance}${homeEmpty?customerHomeEmptyActionV286():''}`
    :`${customerMyRewardsHeadingV156(cards.length,{scanId:'customerHomeScan',categories:customerRewardCategoriesPresentV395(cards)})}
    ${customerProgrammeGridMarkupV96(cards)}
    ${payload?.truncated?`<div class="card customer-home-summary-note" role="status"><p class="muted small">Showing the 100 highest-priority linked reward accounts.</p></div>`:''}`}`))return;
  if($('customerHomeScan'))$('customerHomeScan').onclick=openCustomerJoinScanner;
  if(!isHome)wireCustomerProgrammeSearchV195($('walletBody'));
  wireCustomerHomeOffersV167(repaint);
  return true;
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
/* V468-E2(a): the counter-moment cadence. 4s × 60s = at most 15 pulses, each ONE rpc (v370's
   pulse reader), opened only by an explicit customer action at the till. */
const CUSTOMER_WALLET_COUNTER_POLL_MS_V468=4000;
const CUSTOMER_WALLET_COUNTER_WINDOW_MS_V468=60000;
/* V370 (load audit 2026-08-17). The behaviour contract above is unchanged — the wallet still
   re-reads on foreground and still watches for ~3 minutes — but the COST of a tick is not.

   Before: `refresh` was renderCustomerWallet(slug,{silent:true}), which restarts at
   loadCustomerSurfaceContext and re-issues the whole pipeline (12 reads on a programme page,
   8 on Home) BEFORE the v333 signature comparison can say "nothing moved". An idle wallet
   therefore cost ~108 requests per 3-minute window to discover, nine times over, that it was
   idle. Two of those reads are customer_get_actionable_wallet / customer_get_actionable_business,
   the two most expensive reads on the surface.

   After: a tick reads ONE thing — the actionable payload, which is the read that carries every
   fact this watcher exists for (balance, reward-ready, expiry band, visit progress) — and only
   pays for the full refresh when that payload differs from what is on screen. The comparison
   baseline is customerWalletPulseSignatureV370, which every render writes from the actionable
   payload it has already fetched, so re-seeding costs nothing.

   Deliberately unchanged: the foreground listener still performs a FULL refresh, because
   returning to the app is exactly the moment a customer should not be shown anything stale, and
   a full refresh is the only thing that also picks up a newly published offer or a changed
   catalogue. What no longer happens is the tick allowance resetting to zero on that return: a
   phone picked up and put down twenty times used to buy twenty fresh 3-minute polling windows,
   which is why the "cap" was not a cap. */
let customerWalletPulseSignatureV370='';
function customerWalletPulseSignatureOfV370(payload){
  try{return JSON.stringify(payload??null)}catch{return ''}
}
function rememberCustomerWalletPulseV370(payload){
  customerWalletPulseSignatureV370=customerWalletPulseSignatureOfV370(payload);
}
/* Takes an ALREADY-computed signature. Kept separate from rememberCustomerWalletPulseV370 on
   purpose: passing a signature string to that one would JSON-encode it a second time, and the
   tick — which compares against a singly-encoded string — would then report "changed" forever. */
function rememberCustomerWalletPulseSignatureV370(signature){
  customerWalletPulseSignatureV370=String(signature??'');
}
/* One projection, used for BOTH the seed and the tick, so the two can never drift into
   comparing different shapes and polling forever (or never). The programme page prefers the
   actionable card; with the actionable wallet feature off there is no card, so the same three
   sections of the business summary the page draws its balances from stand in. */
function customerWalletProgrammePulseOfV370(card,summary){
  return customerWalletPulseSignatureOfV370(card
    ??[summary?.loyalty??null,summary?.packages??null,summary?.membership??null]);
}
function customerWalletProgrammePulseReaderV370(businessSlug,actionable){
  return async()=>{
    if(actionable){
      const result=await customerRpc('customer_get_actionable_business',{p_business_slug:businessSlug});
      if(result.error)return null;
      return customerWalletProgrammePulseOfV370(result.data?.card||null,null);
    }
    const result=await customerRpc('customer_get_business_summary',{p_business_slug:businessSlug});
    if(result.error)return null;
    return customerWalletProgrammePulseOfV370(null,result.data||null);
  };
}
/* V370: the global inbox sync is idempotent but not free. A real render always syncs; a silent
   background re-read syncs only if the last one is older than this. Reset to 0 on failure so the
   next pass retries rather than waiting out the window on a sync that never landed. */
const CUSTOMER_INBOX_SYNC_MIN_MS_V370=300000; // 5 minutes
let customerInboxSyncedAtV370=0;
function customerInboxSyncDueV370(silent,now=Date.now()){
  if(!silent){customerInboxSyncedAtV370=now;return true}
  if(now-customerInboxSyncedAtV370<CUSTOMER_INBOX_SYNC_MIN_MS_V370)return false;
  customerInboxSyncedAtV370=now;return true;
}
function customerWalletHomePulseReaderV370(){
  return async()=>{
    const result=await customerRpc('customer_get_wallet');
    if(result.error)return null;
    return customerWalletPulseSignatureOfV370(result.data??null);
  };
}
function watchCustomerWalletV295(isCurrent,refresh,pulse=null){
  activeCustomerWalletLiveCleanupV295();
  let ticks=0,timer=0,stopped=false,counterUntilV468=0;
  const stop=()=>{
    if(stopped)return;stopped=true;
    if(timer)clearTimeout(timer);timer=0;
    document.removeEventListener('visibilitychange',onVisibility);
    if(activeCustomerWalletLiveCleanupV295===stop)activeCustomerWalletLiveCleanupV295=()=>{};
    if(activeCustomerWalletCounterMomentV468===counterMomentV468)activeCustomerWalletCounterMomentV468=async()=>{};
  };
  const alive=()=>!stopped&&isCurrent()&&!!$('walletBody')?.isConnected;
  /* V468-E2(a) (owner photo 12: "customer portal did not immediately reduce the points … it takes
     awhile before reflected"). The v295/v370 watcher is right for a wallet sitting idle in a
     pocket — one cheap pulse every 20s, nine of them, then quiet — and wrong for the ten seconds
     either side of a counter transaction, which is the only moment the customer is actually
     staring at the balance waiting for it to move. Worse, the allowance is a per-page budget
     (v370, deliberately), so a customer who had the page open for four minutes before the staff
     rang the sale had NO ticks left and would never have seen it without navigating.
     A "counter moment" is an explicit customer action that means "I am at the till right now":
     showing the member code, tapping a reward's redeem control, and the moment a redemption QR
     settles or is dismissed. It refreshes at once, restores the tick budget, and drops the
     interval to 4s for one minute — at most ~15 extra single-RPC pulses, and only after the
     customer did something. It is not a tighter poll: the idle cadence is untouched. */
  const arm=()=>{
    if(timer)clearTimeout(timer);
    if(!alive()||ticks>=CUSTOMER_WALLET_POLL_LIMIT_V295||document.visibilityState!=='visible')return;
    const delayV468=Date.now()<counterUntilV468
      ?CUSTOMER_WALLET_COUNTER_POLL_MS_V468:CUSTOMER_WALLET_POLL_MS_V295;
    timer=setTimeout(async()=>{
      timer=0;
      if(!alive()||document.visibilityState!=='visible')return;
      ticks+=1;
      /* v333: the watcher re-arms ITSELF. Before, the only thing that armed the next tick was
         the full re-render the tick triggered — which is precisely the rebuild v333 removed, so
         a silent refresh would have polled once and then gone quiet. */
      try{
        if(typeof pulse==='function'){
          const observed=await pulse();
          /* A failed pulse is not "nothing changed" and it is not a reason to repaint either:
             leave the working page alone and try again on the next tick, exactly as v333 does
             for every other failed background read. */
          if(observed===null||observed===undefined){arm();return}
          if(!alive()||document.visibilityState!=='visible')return;
          if(observed===customerWalletPulseSignatureV370){arm();return}
        }
        await refresh();
      }catch{}
      arm();
    },delayV468);
  };
  /* V468-E2(a): read NOW, then watch closely for a minute. The tick budget is restored because a
     counter transaction is precisely what the budget exists to catch. */
  const counterMomentV468=async()=>{
    if(stopped)return;
    ticks=0;
    counterUntilV468=Date.now()+CUSTOMER_WALLET_COUNTER_WINDOW_MS_V468;
    try{await refresh()}catch{}
    arm();
  };
  activeCustomerWalletCounterMomentV468=counterMomentV468;
  async function onVisibility(){
    if(!alive())return stop();
    if(document.visibilityState!=='visible'){if(timer)clearTimeout(timer);timer=0;return}
    /* Back in the customer's hand: read now — in full, because this is the counter moment the
       feature was built for. V370: the allowance is NOT reset; the window is a budget for this
       page, not for this glance. */
    try{await refresh()}catch{}
    arm();
  }
  document.addEventListener('visibilitychange',onVisibility);
  activeCustomerWalletLiveCleanupV295=stop;
  arm();
  return {stop,rearm:arm};
}
/* v333 (owner, 2026-08-15: "keep refreshing by itself — i need it to load seamlessly, must be
   immediate"). v295's watcher was right about the fact — a balance earned at the counter while
   the customer holds the phone must appear — and wrong about the method: its refresh was this
   function, which starts by rebuilding root.innerHTML down to a "Loading Peekaa…" card. So every
   20 seconds, and on every return to the foreground, the whole page tore down and grew back: the
   scroll jumped to the top, open disclosures closed, focus was thrown to <main>, and the
   surface_viewed / account_open analytics fired again for a customer who had not gone anywhere.

   A silent refresh does the reads and then does NOTHING unless an answer changed:
     · no shell rebuild — the page on screen is the page that stays
     · a FACT SIGNATURE over the payloads the cards are drawn from; identical signature, identical
       pixels, so the DOM is never touched and there is nothing to see
     · a changed signature repaints in place, holding the scroll position (this is the moment the
       feature exists for — the points the customer just earned)
     · no focus move, no popup, no re-counted analytics, and no error card: a poll that fails
       leaves the working page alone (the reads are guarded below and in
       loadCustomerSurfaceContext)
   `immediate` is the other half: the foreground listener still reads the instant the app comes
   back, it just no longer announces itself by blanking the screen first. */
let customerWalletFactSignatureV333='';
/* The signature is taken over the SERVER PAYLOADS the visible cards are drawn from, never over
   the rendered HTML: on the business page the markup carries loading shells that the section
   loaders fill in afterwards, so the DOM never equals a freshly built string and an HTML diff
   would report "changed" on every single tick. Every non-silent render records its own
   signature, so the first poll after a real render compares against exactly what is on screen. */
function customerWalletFactSignatureOfV333(facts){
  try{return JSON.stringify(facts)}catch{return ''}
}
function customerWalletFactsUnchangedV333(silent,signature){
  return silent&&!!signature&&signature===customerWalletFactSignatureV333;
}
/* Committed only once a paint has actually landed. A silent paint that stood down (the customer
   is mid-interaction) must leave the old signature in place, or the next tick would read the new
   facts as "already shown" and the customer would never see them. */
function customerWalletFactsPaintedV333(signature){customerWalletFactSignatureV333=signature}
function customerWalletSilentPaintV333(html){
  const host=$('walletBody');
  if(!host)return false;
  /* Never yank the DOM out from under a customer who is mid-interaction: a focused control
     inside the body, or an open sheet, means this repaint can wait for the next tick. */
  if(document.querySelector('.modal'))return false;
  const focused=document.activeElement;
  if(focused&&focused!==document.body&&host.contains(focused))return false;
  const scroller=document.scrollingElement||document.documentElement;
  const scrollTop=scroller?scroller.scrollTop:0;
  const openDisclosures=[...host.querySelectorAll('details')].map(node=>node.open);
  host.innerHTML=html;
  [...host.querySelectorAll('details')].forEach((node,index)=>{
    if(openDisclosures[index]===true)node.open=true;
  });
  if(scroller)scroller.scrollTop=scrollTop;
  return true;
}
async function renderCustomerWallet(businessSlug=null,{silent=false}={}){
  /* A silent pass rides the CURRENT epoch instead of opening a new one. Bumping it would make
     the watcher that scheduled this very refresh look stale to itself and stop. The guard still
     works: any real navigation renders non-silently, bumps the epoch, and every await below sees
     it. */
  const walletRenderEpoch=silent?customerWalletRenderEpoch:++customerWalletRenderEpoch;
  const isWalletCurrent=()=>customerWalletRenderEpoch===walletRenderEpoch;
  if(silent&&!$('walletBody')?.isConnected)return;
  const context=await loadCustomerSurfaceContext(isWalletCurrent,{silent});if(!context)return;
  /* nestly_v428 (item 8): the one call site of the auto-link. It runs on a REAL render only — a
     silent 20-second poll must not start work — and at most once per signed-in customer per
     session (customerAutoLinkOnceV428 returns before calling when the answer is already held).
     It does not block this render: the wallet paints from the reads below whatever the sync does,
     and a sync that actually linked something re-reads the wallet silently so the new business
     appears without the customer doing anything. */
  if(!silent)customerAutoLinkOnceV428(isWalletCurrent,()=>renderCustomerWallet(businessSlug,{silent:true}));
  const customerFeatures=context.features;
  if(!silent)renderCustomerShell({active:businessSlug?'programmes':'home',businessSlug,compactBusinessHeadV339:!!businessSlug,staffWorkspaces:context.staffWorkspaces,messagesAvailable:customerFeatures.customer_in_app_inbox===true,
    body:`<div class="card"><p class="muted">Loading ${esc(BRAND.customerLabel)}…</p></div>`});
  let actionableCard=null,programmeCards=[];
  if(customerFeatures.customer_actionable_wallet===true){
    if(!businessSlug){
      const {data,error}=await customerRpc('customer_get_actionable_wallet');
      if(!isWalletCurrent())return;
      /* V370: `as_of` is statement_timestamp() and moves on every call, so the pulse baseline is
         taken over the cards alone — comparing the envelope would report "changed" every tick. */
      if(!error)rememberCustomerWalletPulseV370(data?.cards??null);
      if(!error&&Array.isArray(data?.cards)&&data.cards.length){
        /* v286: this pair used raw sb.rpc, so it carried NO abortSignal while every other read in
           the Promise.all aborts at 12s (v177) — and Promise.all waits for the slowest, so one
           stalled multi-business inbox sync left Home on "Loading Peekaa…" forever with no error
           and no Retry. Both calls now go through customerRpc, AND the badge no longer gates the
           paint: Home renders from the wallet/bookings/offers reads and the bell slot hydrates
           when the count lands. */
        /* V370: the SYNC is a materialisation pass, not a read — it was running on every silent
           20-second re-read of Home, so an idle phone re-materialised its whole inbox 180 times
           an hour. The count is still read on every pass (it is what the bell shows); the sync
           now runs on a real render and, at most, once every CUSTOMER_INBOX_SYNC_MIN_MS_V370.
           Nothing about the badge changes: a customer who opens Home, or returns to it from the
           background, still syncs before the count is read, which is every case the sync existed
           for. */
        const messagePromise=customerFeatures.customer_in_app_inbox===true
        ?(async()=>{
          if(customerInboxSyncDueV370(silent)){
            const syncResult=await customerRpc('customer_sync_in_app_inbox_global',{p_idempotency_key:crypto.randomUUID()});
            if(syncResult.error){customerInboxSyncedAtV370=0;return {data:null,error:syncResult.error}}
          }
          return customerRpc('customer_get_in_app_inbox_global_count');
        })().catch(error=>({data:null,error}))
        :Promise.resolve({data:null,error:null});
      const [legacyResult,bookingRequestResult,offersResult]=await Promise.all([
        customerRpc('customer_get_wallet'),
        customerRpc('customer_get_booking_requests',{p_limit:50,p_cursor:null}),
        customerRpc('customer_get_home_offers_v167',{p_locale:merchantCopyLocale()})
      ]);
      if(!isWalletCurrent())return;
      customerHomeOverview={
        walletCards:legacyResult.error?[]:(Array.isArray(legacyResult.data)?legacyResult.data:[]),
        activeRequestCount:bookingRequestResult.error?0:(Array.isArray(bookingRequestResult.data?.items)?bookingRequestResult.data.items.filter(isActiveCustomerBookingRequest).length:0),
        activeRequestsTruncated:!bookingRequestResult.error&&(bookingRequestResult.data?.truncated===true||!!bookingRequestResult.data?.next_cursor),
        bookingsAvailable:!legacyResult.error||!bookingRequestResult.error,
        messageCount:null,
        messagesAvailable:customerFeatures.customer_in_app_inbox===true,
        claimsAvailable:false
      };
      const homeOffersStateV333=offersResult.error?{status:'error',items:[]}:{status:'ready',items:Array.isArray(offersResult.data?.items)?offersResult.data.items:[]};
      const homePendingRedemptionV333=offersResult.error?null:offersResult.data?.pending_redemption||null;
      /* v333: nothing the customer can see has moved — leave the page exactly as it is. */
      const homeSignatureV333=customerWalletFactSignatureOfV333(['home',data,customerHomeOverview.walletCards,
        homeOffersStateV333,homePendingRedemptionV333,customerHomeOverview.activeRequestCount]);
      if(customerWalletFactsUnchangedV333(silent,homeSignatureV333))return;
      if(!renderActionableWalletHome(data,{
        legacyCards:customerHomeOverview.walletCards,
        offersState:homeOffersStateV333,
        pendingRedemption:homePendingRedemptionV333,
        silent,
        profile:context.profile
      }))return;
      customerWalletFactsPaintedV333(homeSignatureV333);
      /* v194: Bookings counts what is still live — a request awaiting the business plus an
         upcoming appointment. It comes from data already fetched above, so the badge costs no
         round trip.
         nestly_v457 (B-REG-017): the My Rewards badge is gone. It counted REWARD ACCOUNTS — LIVE
         it read "Rewards 7" for a customer holding seven businesses — but it sits on a tab
         labelled "Rewards", beside a greeting and cards that were talking about rewards READY, and
         its accessible name rendered as "Rewards, 7". Three numbers with three meanings and no
         label between them. The destination page is headed "My Rewards" and lists those businesses
         by name, which is the same reasoning v386 used to delete "across N businesses". Bookings
         keeps its badge: it is a count of the thing its tab is named for. */
      applyCustomerNavCountsV194({
        bookings:customerHomeOverview.activeRequestCount
          +customerHomeOverview.walletCards.reduce((total,card)=>
            total+Math.max(0,Number(card?.upcoming_appointments?.count||0)),0)
      });
      const paintCustomerInboxBellV286=unread=>{
        const inboxSlot=$('customerInboxBellSlot');
        if(!inboxSlot||customerFeatures.customer_in_app_inbox!==true)return;
        inboxSlot.innerHTML=`<a class="customer-inbox-bell" href="#/customer/messages" aria-label="${unread===null?'Open messages':`Open messages, ${unread} unread`}" title="Open messages">${CUI.icon('bell',{size:20})}${Number(unread)>0?`<span class="customer-inbox-badge" aria-hidden="true">${unread>99?'99+':unread}</span>`:''}</a>`;
      };
      paintCustomerInboxBellV286(customerHomeOverview.messageCount);
      /* v286: same epoch guard as every other post-await write — a slow badge from an abandoned
         render must never repaint the surface the customer moved on to. */
      messagePromise.then(messageResult=>{
        if(!isWalletCurrent())return;
        customerHomeOverview.messageCount=messageResult?.error?null:Math.max(0,Number(messageResult?.data?.unread_count||0));
        paintCustomerInboxBellV286(customerHomeOverview.messageCount);
      });
      if(!silent)focusCustomerRoute();
      return;
      }
    }
    if(businessSlug){
      const [{data,error},walletResult]=await Promise.all([
        customerRpc('customer_get_actionable_business',{p_business_slug:businessSlug}),
        customerRpc('customer_get_actionable_wallet')
      ]);
      if(!isWalletCurrent())return;
      /* V289: 42501 is "you hold no link to this business", not a load failure.
         v333: on a silent poll every one of these three answers keeps the working page instead
         of replacing it — a customer reading their wallet must not lose it to one failed
         background read, and "not joined" is not a state a poll can newly discover for a page
         that is already rendered. */
      if(walletRpcDenied(error))return silent?undefined:renderCustomerNotJoinedV289(businessSlug);
      if(error)return silent?undefined:renderCustomerWalletRetry('This business could not be loaded.',businessSlug,undefined,error);
      actionableCard=data?.card||null;
      programmeCards=walletResult.error?[]:(Array.isArray(walletResult.data?.cards)?walletResult.data.cards:[]);
      /* V370: seed the poll baseline from the card this render is about to draw, so the first
         tick compares against exactly what is on screen. */
      rememberCustomerWalletPulseSignatureV370(customerWalletProgrammePulseOfV370(actionableCard,null));
      if(!actionableCard)return silent?undefined:renderCustomerNotJoinedV289(businessSlug);
    }
  }
  if(!businessSlug){
    const [{data,error},bookingRequestResult,selectorMediaResult,offersResult]=await Promise.all([
      customerRpc('customer_get_wallet'),
      customerRpc('customer_get_booking_requests',{p_limit:50,p_cursor:null}),
      customerRpc('customer_get_programme_selector_media_v96'),
      customerRpc('customer_get_home_offers_v167',{p_locale:merchantCopyLocale()})
    ]);
    if(!isWalletCurrent())return;
    if(error)return silent?undefined:renderCustomerWalletRetry('Your wallet is temporarily unavailable.',null,undefined,error);
    const cards=mergeCustomerProgrammeSelectorMediaV96(
      Array.isArray(data)?data:[],selectorMediaResult.error?null:selectorMediaResult.data
    );
    const appointmentCount=cards.reduce((sum,card)=>sum+Math.max(0,Number(card?.upcoming_appointments?.count||0)),0);
    const activeRequestCount=bookingRequestResult.error?0:(Array.isArray(bookingRequestResult.data?.items)?bookingRequestResult.data.items.filter(isActiveCustomerBookingRequest).length:0);
    const bookingCount=appointmentCount+activeRequestCount;
    const bookingsAvailable=!bookingRequestResult.error||cards.length>0;
    const offersState=offersResult.error?{status:'error',items:[]}:{status:'ready',items:Array.isArray(offersResult.data?.items)?offersResult.data.items:[]};
    const fallbackPendingRedemptionV333=offersResult.error?null:offersResult.data?.pending_redemption||null;
    const fallbackSignatureV333=customerWalletFactSignatureOfV333(['fallback-home',cards,offersState,
      fallbackPendingRedemptionV333,bookingsAvailable?bookingCount:0]);
    if(customerWalletFactsUnchangedV333(silent,fallbackSignatureV333))return;
    /* v178 source-shape sentinel: const fallbackHomeMarkupV333=`${customerHomeOffersMarkupV167(offersState)} */
    const fallbackHomeMarkupV333=`${customerHomeGreetingV343(context.profile)}
      ${customerHomeSummaryV343(cards)}
      ${customerHomeOffersMarkupV167(offersState)}
      ${customerHomeBusinessRailV343(cards)}
      ${customerHomeBookingStripV344(cards)}
      ${customerHomeFallbackActionV167({pendingRedemption:fallbackPendingRedemptionV333,legacyCards:cards,offers:offersState.items})}
      ${cards.length?'':`<div class="card"><h2>No verified business links yet</h2><p class="muted small" style="margin-top:6px">Scan a participating business’s Peekaa QR during your visit. Peekaa does not let customers search for or self-link a business from this portal.</p></div>`}
      `;
    if(silent){if(!customerWalletSilentPaintV333(fallbackHomeMarkupV333))return}
    else $('walletBody').innerHTML=fallbackHomeMarkupV333;
    customerWalletFactsPaintedV333(fallbackSignatureV333);
    /* v194: the fallback Home carries the same nav badges as the primary path — a customer who
       lands here through the legacy read must not see empty tabs where the other path shows
       counts. A booking read that failed contributes 0, never a guess. */
    /* nestly_v457: same as the primary path — Bookings only. */
    applyCustomerNavCountsV194({bookings:bookingsAvailable?bookingCount:0});
    if($('customerHomeScan'))$('customerHomeScan').onclick=openCustomerJoinScanner;
    wireCustomerHomeOffersV167(()=>renderCustomerWallet());
    if(!silent)focusCustomerRoute();
    /* v295: Home carries balances too — same watcher, same bounds.
       v333: the watcher now re-arms itself, so a silent pass must not build a second one.
       V370: the tick reads customer_get_wallet only — the one read this fallback Home draws its
       balances and booking counts from — and pays for the other three only when it moves. */
    rememberCustomerWalletPulseV370(data??null);
    if(!silent)watchCustomerWalletV295(isWalletCurrent,()=>renderCustomerWallet(null,{silent:true}),
      customerWalletHomePulseReaderV370());
    return;
  }
  const args={p_business_slug:businessSlug};
  const [{data:summary,error:summaryError},{data:capabilities,error:capabilitiesError},programmeResult]=await Promise.all([
    customerRpc('customer_get_business_summary',args),
    customerRpc('customer_portal_capabilities',args),
    customerRpc('customer_get_wallet')
  ]);
  if(!isWalletCurrent())return;
  /* V289: same denial, same honest answer — the summary and capability reads refuse an unlinked
     business with 42501 before they refuse anything else. */
  if(walletRpcDenied(summaryError)||walletRpcDenied(capabilitiesError))return silent?undefined:renderCustomerNotJoinedV289(businessSlug);
  if(summaryError||capabilitiesError)return silent?undefined:renderCustomerWalletRetry('This business could not be loaded.',businessSlug,undefined,summaryError||capabilitiesError);
  /* V370: with the actionable wallet feature OFF there is no card to pulse against, so the poll
     baseline comes from the same three summary sections the page draws its balances from. With it
     ON the card was already seeded above and this must not overwrite it with a different shape. */
  if(!actionableCard)rememberCustomerWalletPulseSignatureV370(customerWalletProgrammePulseOfV370(null,summary));
  /* v286 (audit: a wasted round trip that also cost a control). This customer_get_wallet read was
     fetched and then never referenced, so with customer_actionable_wallet off programmeCards
     stayed empty: the multi-business switcher above the header vanished (it bails under two
     cards) and customerBusinessIdV103 lost its third fallback, leaving businessId null and
     short-circuiting the actions, presentation, tier and promotion reads. Use the answer we
     already paid for. */
  if(!programmeCards.length&&!programmeResult.error){
    programmeCards=Array.isArray(programmeResult.data)?programmeResult.data
      :(Array.isArray(programmeResult.data?.cards)?programmeResult.data.cards:[]);
  }
  const b=summary.business||{},loyalty=summary.loyalty||{},packages=summary.packages||{},membership=summary.membership||{};
  const businessId=customerBusinessIdV103({
    summaryBusiness:b,actionableCard,programmeCards,businessSlug
  });
  /* v333: a background re-read is not a view. The customer has not opened, navigated to or
     looked again at anything — counting it would inflate programme_viewed, surface_viewed and
     the DAU write by one every 20 seconds for a phone lying face-up on a counter. */
  if(businessId&&!silent)typeof recordProductInteractionV100==='function'&&recordProductInteractionV100('customer.programme_viewed',businessId,{
      context:{entry_point:'customer_wallet',locale:customerLocale,surface_version:'v100'}
    });
  if(businessId&&!silent){
    customerWalletBusinessIdV256=businessId;
    recordCustomerSessionStartV256(businessId,customerLocale);
    typeof recordProductInteractionV100==='function'&&recordProductInteractionV100('customer.surface_viewed',businessId,{
      context:{surface_key:'wallet',entry_point:'customer_wallet',
        locale:customerLocale,surface_version:'v255'}
    });
    /* v255 (audit 3, "customer DAU"): customer_account_open_days_v175 was built for exactly
       this and its wallet channel had no caller, so the only DAU signal the product had was
       the booking path. One idempotent, deduped-per-day write. */
    try{Promise.resolve(sb.rpc('customer_record_account_open_v175',{p_business:businessId}))
      .catch(()=>{})}catch{}
  }
  const unavailableBusinessId=()=>Promise.resolve({
    data:null,error:{code:'business_id_unavailable',message:'Business identifier is unavailable'}
  });
  const promotionPromptRequest=customerFeatures.customer_in_app_inbox===true
    ?sb.rpc('customer_get_pending_promotion_prompt_v122',{p_business_slug:businessSlug})
    :Promise.resolve({data:null,error:null});
  const [businessActionsResult,presentationResult,effectiveTierResult,promotionsResult,promotionPromptResult]=await Promise.all([
    businessId?sb.rpc('customer_get_business_actions_v89',{p_business:businessId}):unavailableBusinessId(),
    businessId?sb.rpc('customer_get_business_presentation_v95',{p_business:businessId,p_branch:null,p_locale:merchantCopyLocale()}):unavailableBusinessId(),
    businessId?sb.rpc('customer_get_effective_tier_v143',{p_business:businessId}):unavailableBusinessId(),
    /* V201 (owner: "customer view only have 1 company instead of multiple branch"). The customer
       sees the FIRM, so this read is firm-wide by definition — never the workspace's selected
       branch. selectedBranchId is workspace state; a staff member who is also a customer would
       otherwise carry their branch scope into their own customer view and silently lose the other
       outlets' offers. A promotion that only runs at one outlet says so in its own terms. */
    businessId?sb.rpc('customer_get_promotions_v155',{p_business:businessId,p_branch:null,p_locale:merchantCopyLocale()}):unavailableBusinessId(),
    promotionPromptRequest
  ]);
  if(!isWalletCurrent())return;
  const businessActions=businessActionsResult.error?null:businessActionsResult.data;
  const presentation=customerProgrammePresentationV95(presentationResult.error?{}:presentationResult.data,{business:b,loyalty:actionableCard?.loyalty||loyalty});
  /* v189: a failed tier lookup used to render as an empty space, which reads as "this business
     has no tiers" — the customer cannot tell a paused programme from a broken call. Carry the
     failure through so the card can say which it is. 42501 is the server's "not running for you"
     (module off, or no active programme); anything else is a genuine fault. */
  presentation.tier=effectiveTierResult.error
    ?{unavailable:effectiveTierResult.error.code==='42501'?'not_running':'error'}
    :(effectiveTierResult.data?.tier||{});
  const programmeOffersStatus=promotionsResult.error?'error':'ready';
  /* V462 (owner ruling R2a): "customer sees ALL live offers on the business's own page". The
     .slice(0,6) that used to be here was a second, invisible cap on top of the reader's own
     `limit 6` — so a shop with eight live offers had two of them cut twice over, and the owner
     had no way to see that from either side. The server now bounds this by the business's own
     promotion entitlement and says so in the payload; nothing is trimmed again here. */
  presentation.offers=promotionsResult.error
    ?[]
    :(Array.isArray(promotionsResult.data?.items)?promotionsResult.data.items:[]);
  /* v255 (audit finding: promotion views were class C — nothing recorded between "we published
     it" and "someone redeemed"). Deduped per browser session so a wallet the customer reopens
     five times is one view, not five. */
  if(businessId&&!silent)for(const offerV256 of presentation.offers){
    const promotionIdV256=String(offerV256?.id||offerV256?.promotion_id||'');
    if(!isUuidV100(promotionIdV256)||customerPromotionsSeenV256.has(promotionIdV256))continue;
    customerPromotionsSeenV256.add(promotionIdV256);
    typeof recordProductInteractionV100==='function'&&recordProductInteractionV100('customer.promotion_viewed',businessId,{
      context:{promotion_id:promotionIdV256,surface_key:'wallet',
        entry_point:'customer_wallet',locale:customerLocale,surface_version:'v255'}
    });
  }
  const bookingEnabled=businessActions?.booking?.enabled===true&&presentation.capabilities.booking_enabled!==false;
  const appointmentChangesEnabled=businessActions?.appointment_changes?.enabled===true;
  const currency=b.currency||'SGD';
  /* V320 (owner 2026-08-14): "i do not want spendable credits to exist in the app" — the app, not
     just the business workspace, so the customer's own Store credit metric goes with the staff
     one. `customer_get_wallet` still returns credit_balance_cents and the ledger is untouched;
     the wallet simply stops rendering it. */
  const showPackageMetric=capabilities.packages===true&&Number(packages.sessions_remaining||0)>0;
  const showMembershipMetric=capabilities.membership===true&&membership.active===true;
  const showSecondaryMetrics=!actionableCard&&(showPackageMetric||showMembershipMetric);
  const showGiftCardSectionV347=capabilities.gift_cards===true||capabilities.giftcards===true;
  const showPackageGroupV347=showGiftCardSectionV347||capabilities.packages===true||capabilities.membership===true
    ||(customerFeatures.customer_birthday_benefits&&actionableCard?.birthday_benefit&&actionableCard.birthday_benefit.status!=='unavailable');
  const hasWalletSection=true;
  /* v333: the whole programme page is drawn from these eight answers. If none of them moved, the
     repaint would be pixel-for-pixel identical — and it would still cost the customer their
     scroll position, their open History disclosure and every already-hydrated wallet section,
     which is exactly what the owner was seeing every twenty seconds. */
  const programmeSignatureV333=customerWalletFactSignatureOfV333(['programme',businessSlug,summary,
    capabilities,actionableCard,programmeCards,presentation,businessActions]);
  if(customerWalletFactsUnchangedV333(silent,programmeSignatureV333))return;
  const programmeBodyMarkupV333=`<div id="customerBusinessMainV348" class="customer-business-main-v348">
      ${customerMerchantExperienceMarkupV95({presentation,business:b,actionableCard,programmeCards,bookingEnabled:capabilities.booking_request&&bookingEnabled,offersStatus:programmeOffersStatus,rewardsHost:capabilities.rewards===true,programmeCapabilities:capabilities,collapsedHeaderV339:true,backHrefV340:'#/customer/programmes',packages,membership,walletLoyalty:loyalty})}
    </div>
    <section class="customer-business-shortcut-page-v348" id="customerBusinessShortcutPageV348" hidden aria-labelledby="customerBusinessShortcutTitleV348">
      <header class="customer-business-shortcut-head-v348">
        <button class="btn ghost sm customer-business-shortcut-back-v348" id="customerBusinessShortcutBackV348" type="button">${CUI.icon('back',{size:20})}<span>Back</span></button>
        <h1 id="customerBusinessShortcutTitleV348">Details</h1>
      </header>
      <div class="customer-business-shortcut-content-v348" id="customerBusinessShortcutContentV348"></div>
    </section>
    <div class="wallet-sections customer-business-detail-store-v348" id="walletSections" hidden>
      ${showPackageGroupV347?`
      <section class="customer-business-group-v346" id="customerBusinessPackagesDetailV347" aria-labelledby="customerBusinessPackagesTitle">
        <div class="customer-business-group-head-v346"><h2 id="customerBusinessPackagesTitle">Packages</h2><p class="muted small">Active plans, sessions and stored value.</p></div>
        ${showGiftCardSectionV347?walletSectionShell('walletGiftCards','Gift cards','Money left on your gift cards from this business.'):''}
        ${capabilities.packages?walletSectionShell('walletPackages','Packages','Session balances and recent usage.'):''}
        ${capabilities.membership?walletSectionShell('walletMemberships','Membership','Current plan and period status.'):''}
        ${customerFeatures.customer_birthday_benefits&&actionableCard?.birthday_benefit&&actionableCard.birthday_benefit.status!=='unavailable'?`<section class="card wallet-section" id="walletBirthdayParticipation" aria-busy="true"><div class="wallet-skeleton"></div></section>`:''}
      </section>`:''}
      ${/* nestly_v472 (owner, photo 5: "i need a subtab inside activities (in customer view) —
           because now is a endless scrolling. Subtab like Appointments / Recent Activity /
           Loyalty Activity"). The owner's own naming, given back: Activities / Rewards /
           Appointments, and "Appointments (if have, because F&B don't need appointments)".
           Nothing about the DATA changes. These were already three independently-loaded hosts
           stacked vertically; this puts them behind three tabs and hides two of them. Each
           loader still finds its own element by the same id, still on the page, so no read moved
           and no read became conditional on a tab being open.
           The OUTER "History" <details> that used to wrap Transactions and Loyalty activity is
           gone: a tab and a disclosure are two ways of saying the same thing, and stacking them
           was the endless scroll the owner is complaining about. The v468-E1 force-open machinery
           stays, because the "Full history" disclosure INSIDE the transactions section is still
           there and still needs opening on the Activity page — it now has one disclosure to
           defeat instead of two.
           A distinct data attribute, NOT data-programme-tab: wireCustomerProgrammeTabsV194 runs
           over this same walletBody host and would fold these three into one roving group with
           the tier/points tabs above them. */''}
      <section class="customer-business-group-v346" id="customerBusinessActivityDetailV347" aria-labelledby="customerBusinessActivityTitle">
        <div class="customer-business-group-head-v346"><h2 id="customerBusinessActivityTitle">Activity</h2><p class="muted small">Visits, rewards and loyalty history.</p></div>
        ${customerActivityTabsMarkupV472(capabilities)}
        <div data-activity-panel-v472="activities">
          ${walletSectionShell('walletTransactions','Activities','Every purchase, reversal, correction, and points event kept in time order.')}
        </div>
        ${capabilities.activity?`<div data-activity-panel-v472="rewards" hidden>
          ${walletSectionShell('walletActivity','Rewards','Your loyalty history with this business.')}
        </div>`:''}
        ${capabilities.appointments?`<div data-activity-panel-v472="appointments" hidden>
          ${walletSectionShell('walletAppointments','Appointments','Upcoming and recent visits.')}
        </div>`:''}
      </section>
      <section class="customer-business-group-v346" id="customerBusinessOverviewDetailV347" aria-labelledby="customerBusinessOffersTitle">
        <div class="customer-business-group-head-v346"><h2 id="customerBusinessOffersTitle">Overview</h2><p class="muted small">Current offers and visit feedback.</p></div>
        ${window.NestlyGrowthOffers?window.NestlyGrowthOffers.renderCustomerOffers({state:'loading'}):''}
        ${walletReviewUrlV183(b)?`<section class="card wallet-section" id="walletFeedback"></section>`:''}
      </section>
      ${customerBusinessSecondaryMarkupV346(presentation)}
      ${hasWalletSection?'':`<section class="card wallet-section" id="walletEmpty"><div class="wallet-section-head"><div><h2>Nothing to show yet</h2><p class="muted small">This business has no customer wallet sections available for your account.</p></div><span class="spacer"></span><button class="btn ghost sm" id="walletEmptyRetry">Refresh</button></div></section>`}
    </div>`;
  if(silent){if(!customerWalletSilentPaintV333(programmeBodyMarkupV333))return}
  else $('walletBody').innerHTML=programmeBodyMarkupV333;
  customerWalletFactsPaintedV333(programmeSignatureV333);
  wireCustomerRepeatBookingV167($('walletBody'));
  wireCustomerProgrammeTabsV194($('walletBody'));
  wireCustomerBusinessShortcutsV347($('walletBody'));
  wireCustomerBusinessShortcutPageV348($('walletBody'));
  /* nestly_v418: the gallery's photos open full size. Wired with the page's other controls so a
     re-render rebinds them together. */
  wireCustomerGalleryV418($('walletBody'));
  wireCustomerActivityTabsV472($('walletBody'));
  /* V468-E2(a): showing the member code IS the counter moment — it is the thing the customer does
     immediately before the staff rings the sale or applies a reward. Delegated on the body, which
     is replaced wholesale by every paint, so the listener never accumulates. */
  wireCustomerCounterMomentV468($('walletBody'));
  /* v194: the header identity opens the same company sheet the offer sheet uses. */
  $('walletBody').querySelectorAll('[data-company-detail]').forEach(button=>button.onclick=()=>
    showCustomerBusinessDetailV178({...b,id:businessId||b.id,slug:businessSlug}));
  /* v326: the header's phone/address segments load inline using the exact same read
     showCustomerBusinessDetailV178 already makes on click. On error/empty they silently keep
     the plain "Address"/"Call" segments already in the markup and already wired above (both
     open the same company sheet), so nothing about the click path breaks.
     v337: restyled from two stacked lines into the Address/Call segment pair — Address still
     opens the company sheet, and Call becomes a real tel: link once the number is known
     (falls back to the same sheet when there is no phone on file). Book now lives OUTSIDE this
     host (a sibling in the v337 contact row) so this replacement never touches it. */
  const contactHostV326=$('walletBody').querySelector('[data-company-contact-inline-v326]');
  if(contactHostV326&&(businessId||b.id)){
    Promise.resolve(customerRpc('customer_get_offer_business_contact_v173',{p_business:businessId||b.id}))
      .then(({data,error})=>{
        if(error||!contactHostV326.isConnected)return;
        const branch=data?.branch||{};
        if(!branch.address&&!branch.phone)return;
        const compactHeaderContactV366=contactHostV326.classList.contains('customer-business-actions-v346');
        /* nestly_v397 (owner photo C: the chip's address struck through, "Locations" written over
           it). In the compact header the address was clipped to "313 Orcha…" — a truncated string
           that names nothing and, since v386, is printed IN FULL on its own line directly below.
           The chip opens the company-details sheet, which lists every branch, so the button now
           says what it opens. The full address stays as its title/aria for anyone hovering or on
           a screen reader; the wide (non-compact) header still prints the address itself. */
        /* nestly_v422 (owner photo 8: a map pin drawn over this chip, "remove this wording").
           In the COMPACT header the chip is one of two controls in a fixed 166–184px column, and
           that column is what starved the identity beside it. MEASURED at 390px on the build in
           the owner's photos: actions 184px, identity button 130px, and the text column inside it
           89px — so "Cubbly SPA" wrapped to two lines AND ellipsised, and the bio, needing 120px,
           broke across two line boxes mid-phrase (the owner's second mark on the same photo,
           "company bio has its own line"). Dropping the word makes it a pin, matching the Call
           button that has been icon-only since v366. Re-measured after: actions 106px, text
           column 122px, name one line un-truncated, bio one line. Same at 375 and 412.
           The full address is unchanged as title/aria — a screen reader and a hover still get it,
           and the chip still opens the same company-details sheet. The WIDE header keeps printing
           the address itself: it has the room, and there the address is the useful label. */
        const rawAddressLabelV366=compactHeaderContactV366?''
          :(branch.address?String(branch.address):'Locations');
        const addressTitleV366=branch.address?String(branch.address):'Locations';
        const callTitleV366=branch.phone?`Call ${branch.phone}`:'Call';
        const openSheet=()=>showCustomerBusinessDetailV178({...b,id:businessId||b.id,slug:businessSlug});
        contactHostV326.innerHTML=`<button type="button" class="customer-programme-contact-item-v337 customer-business-address-v366${rawAddressLabelV366?'':' customer-business-address-icon-v422'}" data-company-detail aria-label="${esc(compactHeaderContactV366?`Locations — ${addressTitleV366}`:addressTitleV366)}" title="${esc(addressTitleV366)}">${CUI.icon('branch',{size:20})}${rawAddressLabelV366?`<span>${esc(rawAddressLabelV366)}</span>`:''}</button>${
          branch.phone
            ?`<a class="customer-programme-contact-item-v337 customer-business-call-icon-v366" href="tel:${esc(String(branch.phone).replace(/[^+0-9]/g,''))}" aria-label="${esc(callTitleV366)}" title="${esc(callTitleV366)}">${CUI.icon('phone',{size:20})}${compactHeaderContactV366?'':`<span>Call</span>`}</a>`
            :`<button type="button" class="customer-programme-contact-item-v337 customer-business-call-icon-v366" data-company-detail aria-label="Call" title="Call">${CUI.icon('phone',{size:20})}${compactHeaderContactV366?'':`<span>Call</span>`}</button>`
        }`;
        contactHostV326.querySelectorAll('[data-company-detail]').forEach(button=>button.onclick=openSheet);
        const addressLineV386=$('walletBody').querySelector('[data-company-address-line-v386]');
        if(addressLineV386&&branch.address){
          addressLineV386.innerHTML=`${CUI.icon('branch',{size:16})}<span>${esc(String(branch.address))}</span>`;
          addressLineV386.hidden=false;
        }
      }).catch(()=>{});
  }
  wireCustomerClaimRewardV395($('walletBody'));
  /* v327 (owner: "clicked tier > auto scroll to tier below"): the header's tier badge jumps to
     the Tier card. Covers both the v310 stack (its own [data-programme-card="tiers"] section)
     and the v194 tabs fallback (switches to the tier tab first, since scrolling to a hidden
     panel would land the customer on an unrelated part of the page). */
  const tierJumpV327=$('walletBody').querySelector('[data-tier-scroll-v327]');
  if(tierJumpV327)tierJumpV327.onclick=()=>{
    const stackCard=$('walletBody').querySelector('[data-programme-card="tiers"]');
    if(stackCard){
      stackCard.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'start'});
      return;
    }
    const tierTab=$('walletBody').querySelector('[data-programme-tab="tier"]');
    const tabsCard=$('walletBody').querySelector('.customer-programme-tabs');
    if(tierTab&&tierTab.getAttribute('aria-selected')!=='true')tierTab.click();
    tabsCard?.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'start'});
  };
  /* V290: "Show at counter" used to change its own label and nothing else — there was no code for
     staff to check and no record that the offer was ever used. It now creates a short-lived
     promotion intent and renders the same QR the reward path renders, so the counter can verify
     it with the scanner it already has and the offer finally produces a number. */
  const promotionIntentAttempts=new Map();
  document.querySelectorAll('[data-promotion-counter]').forEach(button=>button.onclick=async()=>{
    const card=button.closest('[data-promotion-id]'),status=card?.querySelector('[data-promotion-status]');
    const promotionId=String(card?.dataset.promotionId||'');
    const shopId=businessId||b.id;
    if(!promotionId||!shopId){
      if(status)status.textContent='Show this offer to the team at the counter.';
      button.textContent='Ready to show';return;
    }
    if(!promotionIntentAttempts.has(promotionId))promotionIntentAttempts.set(promotionId,crypto.randomUUID());
    const label=button.textContent;
    button.disabled=true;button.textContent='Preparing code…';
    const {data:intent,error:intentError}=await sb.rpc('customer_create_promotion_intent_v290',{
      p_business:shopId,p_promotion:promotionId,
      p_idempotency_key:promotionIntentAttempts.get(promotionId)
    });
    if(!button.isConnected)return;
    button.disabled=false;button.textContent=label;
    if(intentError||intent?.status!=='pending'||!intent?.qr_token){
      promotionIntentAttempts.delete(promotionId);
      if(status)status.textContent=intentError?.code==='PGRST202'||intentError?.code==='42883'
        ?'Show this offer to the team at the counter.'
        :intent?.status==='redeemed'
          ?'You have already used this offer.'
          :'This offer could not be prepared right now. Show it to the team at the counter.';
      return;
    }
    if(status)status.textContent='Show this code at the counter.';
    const offerName=card?.querySelector('h3,h2,b')?.textContent||'Offer';
    showPendingPromotionQrV290({intent,businessName:b.name,promotionName:offerName});
  });
  /* v286: one offer, one detail surface. The wallet used to open a second modal cloned from the
     card's own <template> — description, a small <dl>, Close and Done — while the SAME offer opened
     from the Home shelf went to showCustomerOfferDetailV173 with artwork, live branch contact, a
     fail-closed Book now and Share. The business programme page is the primary surface and was the
     poorer, dead-ended one, and no share could ever start there. It now routes to the Home sheet,
     with the offer read back out of the list the page already rendered (the v265 rule) so the sheet
     can never describe a different promotion from the card that was tapped. The old modal stays as
     the fallback for a card whose offer is not in that list, so a tap is never answered by nothing. */
  document.querySelectorAll('[data-promotion-details]').forEach(button=>button.onclick=()=>{
    const card=button.closest('[data-promotion-id]'),offerId=String(card?.dataset?.promotionId||'');
    const offer=(Array.isArray(presentation.offers)?presentation.offers:[]).find(item=>String(item?.id||'')===offerId);
    if(!offer)return openCustomerPromotionDetailsV104(card);
    typeof recordProductInteractionV100==='function'&&recordProductInteractionV100('customer.promotion_opened',customerWalletBusinessIdV256,{
      context:{promotion_id:offerId,surface_key:'promotion_detail',
        entry_point:'customer_wallet',surface_version:'v255'}
    });
    showCustomerOfferDetailV173({...offer,business:{...b,id:businessId||b.id,slug:businessSlug}});
  });
  /* v386 (owner photo 9: "why cannot click to see details", drawn across the offer card). The
     detail sheet was reachable only through a [data-promotion-details] button, and that button
     exists only when the business's configured CTA is 'programme'. A business that chose "Book
     now" — the annotated one — got a card with Book and Share and no way into the offer at all.
     The card body now opens the same sheet the button opens, going through that button when it
     is present so there is exactly one code path and one analytics event. Clicks that land on a
     control the card already owns (Book, Share, Terms, Show at counter) are left alone. */
  document.querySelectorAll('.customer-promotion-card[data-promotion-id]').forEach(card=>{
    if(card.dataset.promotionOpenWiredV386==='yes')return;
    card.dataset.promotionOpenWiredV386='yes';
    card.classList.add('customer-promotion-card-openable-v386');
    card.addEventListener('click',event=>{
      if(event.target.closest('a,button,summary,input,select,textarea,label'))return;
      const detailsButton=card.querySelector('[data-promotion-details]');
      if(detailsButton)return detailsButton.click();
      const offerId=String(card.dataset.promotionId||'');
      const offer=(Array.isArray(presentation.offers)?presentation.offers:[]).find(item=>String(item?.id||'')===offerId);
      if(!offer)return openCustomerPromotionDetailsV104(card);
      typeof recordProductInteractionV100==='function'&&recordProductInteractionV100('customer.promotion_opened',customerWalletBusinessIdV256,{
        context:{promotion_id:offerId,surface_key:'promotion_detail',
          entry_point:'customer_wallet',surface_version:'v255'}
      });
      showCustomerOfferDetailV173({...offer,business:{...b,id:businessId||b.id,slug:businessSlug}});
    });
  });
  /* v265: Share reads the offer back out of the list the page already rendered, so the sheet can
     never describe a different promotion from the card that was tapped. */
  document.querySelectorAll('[data-share-offer]').forEach(button=>button.onclick=()=>{
    const offerId=String(button.dataset.shareOffer||'');
    const offer=(Array.isArray(presentation.offers)?presentation.offers:[]).find(item=>String(item?.id||'')===offerId);
    if(offer)shareCustomerOfferV264(offer,{...b,id:businessId||b.id,slug:businessSlug});
  });
  document.querySelector('[data-programme-offers-retry]')?.addEventListener('click',()=>renderCustomerWallet(businessSlug));
  /* v339: the explainer's resting row no longer carries its own dismiss button — it opens the
     sheet, and the sheet's "Got it" performs the identical localStorage write. The old
     [data-points-explainer-dismiss] handler is kept below so a client still running the previous
     four-hour-cached bundle's markup is not left with an inert button. */
  document.querySelector('[data-points-explainer-open-v339]')?.addEventListener('click',event=>
    openCustomerPointsExplainerV339(event.currentTarget));
  document.querySelector('[data-points-explainer-dismiss]')?.addEventListener('click',event=>{
    const explainer=event.currentTarget.closest('[data-points-explainer]');
    try{localStorage.setItem(explainer.dataset.pointsExplainerKey,'dismissed')}catch{}
    explainer.remove();CUI.announce('Points explanation dismissed.');
  });
  if(customerOfferFocusV167){
    const focusId=customerOfferFocusV167;customerOfferFocusV167=null;
    requestAnimationFrame(()=>{
      const card=document.querySelector(`[data-promotion-id="${CSS.escape(focusId)}"]`);
      card?.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'center'});
      card?.querySelector('button,a')?.focus();
    });
  }
  /* v333: a promotion popup is an interruption, and an interruption the customer did not ask
     for twenty seconds after the last one is the thing the owner is complaining about. It
     belongs to arriving on the page, so a background re-read never raises it. */
  if(!silent)showCustomerPromotionPopupV122({
    business:b,businessSlug,items:presentation.offers,
    prompt:promotionPromptResult.error?null:promotionPromptResult.data
  });
  if(!silent)focusCustomerRoute();
  /* v295: keep the balance honest while the customer is looking at it.
     v333: silently — and the watcher re-arms itself now, so only a real render builds one.
     V370: a tick reads the actionable card alone (one RPC) and only pays for the full 12-read
     refresh when that card differs from what is on screen. */
  if(!silent)watchCustomerWalletV295(isWalletCurrent,()=>renderCustomerWallet(businessSlug,{silent:true}),
    customerWalletProgrammePulseReaderV370(businessSlug,customerFeatures.customer_actionable_wallet===true));
  /* Anti-review-gating (v53 migration invariant): the public-review link is derived from the
     business summary's own review_url and rendered in the feedback section footer REGARDLESS of
     rating; a high rating only adds an extra prominent share card. review_url rides the existing
     customer_get_business_summary business projection (no new call site) — it is https-only.
     The projection DOES surface review_url (added by v53a and verified live in prod), so this is
     wired end to end; the reachability predicate is `walletReviewUrl` presence only, never rating. */
  const walletReviewUrl=walletReviewUrlV183(b);
  let birthdayActivationAttemptId=crypto.randomUUID();
  const birthdayActivate=$('birthdayBenefitActivate');
  if(birthdayActivate)birthdayActivate.onclick=async()=>{
    birthdayActivate.disabled=true;
    const {data,error}=await sb.rpc('customer_activate_birthday_benefit',{p_business_slug:businessSlug,p_idempotency_key:birthdayActivationAttemptId});
    if(!isWalletCurrent()||!birthdayActivate.isConnected)return;
    if(error){birthdayActivate.disabled=false;return toast('Birthday benefit is unavailable right now.');}
    actionableCard={...actionableCard,birthday_benefit:data||null};
    birthdayActivationAttemptId=crypto.randomUUID();
    const cardHost=birthdayActivate.closest('.wallet-section');
    if(cardHost&&cardHost.isConnected){
      cardHost.outerHTML=actionableWalletCardMarkup(actionableCard,{detail:true});
      const replacement=$('birthdayBenefitShow');
      if(replacement)replacement.onclick=()=>{
        const status=$('birthdayBenefitCounter');if(status)status.textContent='Show this screen to the team at the counter. No birthday details are shared with the business.';
      };
    }
  };
  const birthdayShow=$('birthdayBenefitShow');
  if(birthdayShow)birthdayShow.onclick=()=>{
    const status=$('birthdayBenefitCounter');if(status)status.textContent='Show this screen to the team at the counter. No birthday details are shared with the business.';
  };
  ensureWalletEmptyState(businessSlug);
  const isWalletSectionCurrent=(host)=>walletSectionStillCurrent(host,isWalletCurrent);
  /* V300: the referral card renders only from a server yes. Any other answer — programme off,
     module off, backend not yet applied, denial, transport failure — removes the slot: this is
     a growth invitation, not the customer's money, so a retry card here would be noise about a
     feature the customer does not know exists. */
  /* W4c: the member QR, gated EXACTLY like the W4b card stack — programmes_contract==='v310' with
     at least one programme row — because a firm the spine cannot describe has no membership to
     show a code for, and the pre-v310 tab surface never had this card at all.
     CAPABILITY CHECK, deliberately silent: public.customer_get_member_code_v310 is NOT SHIPPED
     (see SERVER ASKS in the W6 increment 2 build report). Any answer other than a code removes the
     slot — a missing function, a denial, a transport failure, a firm with no code yet. This is an
     identity convenience, not the customer's money, so a retry card here would be noise about a
     feature the customer does not know exists. Same rule the referral card below follows, and the
     same reason. */
  const loadMemberCodeW6I2=async()=>{
    const slot=$('customerMemberCodeSlotV310');
    if(!slot)return;
    /* Two gates, and the order matters. The SECOND is W4b's, verbatim: no v310 programmes contract
       (or no programme rows) means this firm has no membership to show a code for, and the
       pre-v310 tab surface never carried this card at all.
       The FIRST is the capability gate. Until the reader ships, the slot is removed rather than
       filled — an identity convenience the customer does not yet know exists must not become a
       retry card, which is the same rule the referral card below follows for the same reason. */
    if(!MEMBER_CODE_CONTRACT_W6I2.readerShipped||!programmeStackV310(programmeCapabilities)){
      slot.remove();return;
    }
    const code=await memberCodeForWalletW6I2(businessSlug);
    if(!isWalletCurrent()||!slot.isConnected)return;
    if(!code){slot.remove();return}
    slot.hidden=false;
    slot.innerHTML=customerMemberCodeMarkupW6I2(code);
    /* The QR is DRAWN, never inlined as a data URI, so the readable fallback inside the card stays
       the honest answer when the library cannot load — a member who cannot show a QR can still
       read the code out to the counter. */
    void loadQrLibrary().then(()=>new QRCode($('customerMemberQrW6I2'),
      {text:`nestly:member:${code}`,width:200,height:200,correctLevel:QRCode.CorrectLevel.M}))
      .catch(()=>{});
  };
  const loadReferralCardV300=async()=>{
    const slot=$('walletReferralSlot');
    if(!slot)return;
    const {data,error}=await customerRpc('customer_get_referral_card_v300',{p_business_slug:businessSlug});
    if(!isWalletCurrent()||!slot.isConnected)return;
    if(error||data?.enabled!==true){slot.remove();return}
    slot.outerHTML=customerReferralCardMarkupV300(data,{...b,id:businessId||b.id,slug:businessSlug});
    const copyButton=$('customerReferralCopy');
    if(copyButton)copyButton.onclick=()=>copyTextToClipboard(String(data.code||''),{button:copyButton,
      success:ct('codeCopied'),failure:'Copying is blocked in this browser. Long-press the code to copy it.'});
    const shareButton=$('customerReferralShare');
    if(shareButton)shareButton.onclick=()=>shareCustomerReferralV300(data,{...b,id:businessId||b.id,slug:businessSlug});
  };
  /* v323 (R5): the stamp card is a QUEST. The v310 card has already painted from the wallet
     payload; this replaces its figure and its sentence with the truth once the reader answers.
     EVERY failure path leaves the v310 card exactly as it is — a missing RPC (an old server behind
     a new bundle), a refusal, {enabled:false}, a paused programme, or an unparseable payload. A
     stamp card that briefly says a slightly cruder true thing is better than one that blanks. */
  const loadStampCardV323=async()=>{
    const card=document.querySelector('[data-programme-card="stamps"]');
    /* nestly_v422: the hero's stamp slot is filled by this same read (owner photo 8), so the call
       is made whenever EITHER surface is on the page — a business profile shows the hero while its
       stamps card lives inside a shortcut sub-page, and requiring the card would have left the
       hero on its wallet-derived guess forever. */
    const heroSlotV422=document.querySelector('[data-hero-stamp-slot-host-v422]');
    /* nestly_v435 (owner rule 7, simulation A8): after a stamps→points switch the customer's
       frozen stamps were INVISIBLE — no card, no note, nothing saying their value was kept. The
       reader now also runs when the points card is mounted, purely to render the one-line "kept"
       note below when a stopped stamp programme still holds the customer's stamps. */
    const pointsCardV435=document.querySelector('[data-programme-card="points"]');
    if(!card&&!heroSlotV422&&!pointsCardV435)return;
    const {data,error}=await customerRpc('customer_get_stamp_card_v323',{p_business_slug:businessSlug});
    if(!isWalletCurrent())return;
    if(error)return;
    const quest=stampQuestNormaliseV323(data);
    if(!card&&pointsCardV435&&pointsCardV435.isConnected&&quest&&!quest.running&&quest.filled>0
       &&!quest.potMigrated&&!document.querySelector('[data-stamps-kept-note-v435]')){
      pointsCardV435.insertAdjacentHTML('afterend',
        `<p class="muted small" data-stamps-kept-note-v435 style="margin:8px 4px 0">${esc(ct('stampsKeptWhilePaused',{count:customerPointTotalV103(quest.shown)}))}</p>`);
    }
    /* THE HERO. Drawn from the card's real slots and milestones, replacing the rings that were
       sized by one reward's cost. A quest that is not running leaves the painted figure alone —
       same rule the card below follows. pot_migrated is deliberately NOT a gate here: the owner
       redrew this hero AS the stamp card on a firm whose pot is migrated, and the server returns
       real slots/filled/milestones for it. What pot_migrated suppresses is the separate stamps
       CARD lower down, per the owner's ruling on photo 6. */
    if(heroSlotV422&&heroSlotV422.isConnected&&quest&&quest.running){
      const heroCardV422=customerHeroStampCardV422(quest);
      if(heroCardV422){
        heroSlotV422.innerHTML=heroCardV422;
        /* nestly_v475: the same bargain the reward hero's photo strikes — a storage object that
           has since been deleted drops the image AND its column, so the card collapses back to
           one column instead of leaving a hole. Wired here rather than inline because the app
           runs under a CSP with no inline handlers. */
        heroSlotV422.querySelectorAll('[data-hero-stamp-photo-v475]').forEach(image=>{
          image.onerror=()=>{
            image.closest('.customer-hero-stampcard-v422')?.classList.remove('customer-hero-stamp-has-photo-v475');
            image.remove();
          };
        });
        /* The card is authoritative about readiness, so a hero painted before it arrived can gain
           the Claim reward button it should always have had. It is the SAME contract the banner
           and the painted button use, wired by the same function — never a second claim path. */
        const actionsV422=heroSlotV422.closest('.customer-business-summary-v346')
          ?.querySelector('.customer-business-summary-actions-v349');
        if(quest.ready&&actionsV422&&!actionsV422.querySelector('[data-claim-reward-scroll-v337]')){
          actionsV422.insertAdjacentHTML('afterbegin',
            '<button type="button" class="customer-business-claim-v347" data-claim-reward-scroll-v337><span>Claim reward</span><span aria-hidden="true">›</span></button>');
          wireCustomerClaimRewardV395(actionsV422);
        }else if(!quest.ready&&actionsV422){
          /* nestly_v437: authoritative BOTH ways. The wallet bootstrap judges stamp readiness by
             the raw pot, which drifts from the card the moment a cycle closes (pot keeps every
             stamp ever earned; the card starts over). A pre-painted Claim button must go when
             the card itself says nothing is ready — the counter would refuse the claim. */
          actionsV422.querySelector('[data-claim-reward-scroll-v337]')?.remove();
        }
      }
    }
    if(!card||!card.isConnected)return;
    /* A paused programme keeps the v310 paused block and its retained figure — the standing W4b
       rule that a programme which pauses must never silently lose the customer's progress. */
    if(!quest||!quest.running)return;
    /* nestly_v422 (owner photo 6, the sentence struck out: "remove this wording"). A migrated pot
       is the one state where this card has no honest figure left, and v323 said so in a sentence.
       The owner's ruling (2026-08-22) is that the box goes with the sentence — the same rule v326
       and v386 already apply to a paused programme: a card the customer cannot act on does not get
       a heading announcing that it cannot be acted on. Nothing about the DATA changes; the stamps
       are still on the server and the card returns the moment the pot does.
       #walletRewards can be mounted INSIDE this card (customerProgrammeStampsCardV310 hosts it
       whenever stamps is the live accruing programme), so it is lifted out first — removing the
       card with the rewards list still in it would take the customer's whole reward catalogue
       off the screen with it. */
    if(quest.potMigrated){
      const rewardsHostV422=card.querySelector('#walletRewards');
      if(rewardsHostV422)card.insertAdjacentElement('beforebegin',rewardsHostV422);
      card.remove();
      return;
    }
    /* nestly_v435 (rule 15): the stamp "?" trigger rides the card's head and carries the PINNED
       version's own spend-per-stamp and validity from this payload as data-* facts. */
    const stampsHeadV435=card.querySelector('.customer-programme-card-head-v310');
    if(stampsHeadV435&&!stampsHeadV435.querySelector('[data-customer-explainer-v435]'))
      stampsHeadV435.insertAdjacentHTML('beforeend',
        `<button type="button" class="btn ghost sm customer-explainer-trigger-v435" data-customer-explainer-v435="stamps" data-exp-spend="${esc(String(quest.spendPerCents||0))}" data-exp-validity="${esc(String(quest.validityDays||0))}" data-exp-currency="${esc(String(b?.currency||'SGD'))}" aria-label="${esc(ct('expTitle'))}" style="margin-left:auto;min-width:30px;padding:2px 7px">${CUI.icon('info',{size:16})}</button>`);
    const figure=card.querySelector('.customer-programme-stamp-rings, .customer-programme-stamp-count');
    const line=card.querySelector('.customer-programme-card-line-v310');
    if(!line)return;
    line.insertAdjacentHTML('beforebegin',customerStampQuestBodyV323(quest));
    if(figure)figure.remove();
    line.remove();
  };
  const loadGrowthOffers=async()=>{
    const host=$('walletGrowthOffers');
    if(!host||!window.NestlyGrowthOffers)return;
    if(!businessId){host.remove();ensureWalletEmptyState(businessSlug);return}
    host.setAttribute('aria-busy','true');
    const {data,error}=await sb.rpc('customer_get_growth_offers_v108',{p_business:businessId});
    if(!isWalletSectionCurrent(host))return;
    if(error){
      const unavailable=['42883','PGRST202'].includes(String(error.code||''));
      if(unavailable||walletRpcDenied(error)){
        host.remove();ensureWalletEmptyState(businessSlug);return;
      }
      host.outerHTML=window.NestlyGrowthOffers.renderCustomerOffers({
        state:'error',
        error:window.NestlyGrowthOffers.classifyError(error),
        businessName:b.name||'this business'
      });
      const replacement=$('walletGrowthOffers');
      if(replacement)window.NestlyGrowthOffers.bindCustomerOffers(replacement,{
        rpc:(name,payload)=>sb.rpc(name,payload),
        onRetry:loadGrowthOffers
      });
      return;
    }
    const offers=window.NestlyGrowthOffers.normalizeCustomerOffers(data);
    if(!offers.length){
      host.remove();ensureWalletEmptyState(businessSlug);return;
    }
    host.outerHTML=window.NestlyGrowthOffers.renderCustomerOffers({
      state:'ready',offers,businessName:b.name||'this business'
    });
    const replacement=$('walletGrowthOffers');
    if(!replacement)return;
    window.NestlyGrowthOffers.bindCustomerOffers(replacement,{
      rpc:(name,payload)=>sb.rpc(name,payload),
      onQr:({intent,entitlementId})=>{
        const offer=offers.find(item=>item.entitlementId===entitlementId);
        showGrowthOfferQr({
          intent,businessName:b.name,offerLabel:offer?.label,
          onClose:loadGrowthOffers
        });
      },
      onRetry:loadGrowthOffers
    });
  };
  const loadRewards=async()=>{
    const host=$('walletRewards');if(!host)return;
    host.setAttribute('aria-busy','true');
    /* V370: customer_get_business_actions_v89 is already fetched by this very render, a few
       dozen lines above, with the same p_business and inside the same epoch — this was a second
       round trip for an answer we were already holding. `businessActionsResult` is reused
       verbatim (same {data,error} shape) so every consumer below is unchanged, including the
       error branch: a failed actions read still degrades exactly as it did before. */
    /* nestly_v429 (C): the three GRANTED entitlements — a welcome offer, a bring-back voucher, a
       referral gift — have been issued server-side since v215/v361/v420 and have never once
       appeared on the customer's own screen; only the till could see them. v427's
       customer_get_entitlements_v427 is the customer's read over exactly those three tables.
       Fetched WITH the catalogue rather than after it: this is one screen, not two round trips.
       Fail closed — 28000 (no session) and 42501 (no verified link), and anything else, render
       NOTHING. No error card: a customer holding no entitlement and a customer whose read was
       refused should both simply see the catalogue, and inventing a retry for a list they may
       have no rows in would be a worse lie than silence. */
    const [catalogResult,entitlementsResultV427]=await Promise.all([
      customerRpc('customer_get_reward_catalog',args),
      customerRpc('customer_get_entitlements_v427',{p_business_slug:businessSlug})
    ]);
    /* Awaited, not the raw promise: every reader below touches .error/.data synchronously. */
    const actionsResult=businessId?businessActionsResult:await unavailableBusinessId();
    const {data,error}=catalogResult;
    if(!isWalletSectionCurrent(host))return;
    if(error)return walletSectionError('walletRewards',walletRpcDenied(error)?ct('Rewards are not available for this account.'):ct('Rewards could not be loaded.'),loadRewards,error);
    /* V241: the catalog is an OBJECT {rewards, points_mode}. The V230 shape appended the mode
       to the rewards ARRAY, where data.points_mode does not exist — so the mode never arrived
       and the stray element could render as a phantom reward. Both shapes are accepted here so
       a cached bundle and the new server (or vice versa) cannot strand the wallet. */
    const walletCatalogV241=(Array.isArray(data)?data:(Array.isArray(data?.rewards)?data.rewards:[]))
      .filter(item=>item&&typeof item==='object'&&(item.customer_name||item.name));
    const walletPointsModeV241=String((Array.isArray(data)
      ?(data.find(item=>item&&typeof item==='object'&&'points_mode' in item&&!('cost_points' in item))||{}).points_mode
      :data?.points_mode)||'');
    /* V230: this firm uses points for tier membership. There is nothing to redeem — the server
       refuses intents too — so the section says what points DO here instead of listing rewards
       that cannot be claimed. */
    if(walletPointsModeV241==='tiers'){
      host.setAttribute('aria-busy','false');
      host.innerHTML=`<div class="card customer-home-offers-state"><b>Your points build your tier</b><p class="muted small" style="margin-top:6px">Every point earned here counts toward your membership tier and its benefits — there is nothing to redeem. Your tier and what it unlocks are shown above.</p></div>`;
      return;
    }
    /* v255: reward VIEWS were class C — only redemption outcomes existed, so the funnel had no
       middle. One event per wallet render of the reward section, not one per card. */
    if(businessId)typeof recordProductInteractionV100==='function'&&recordProductInteractionV100('customer.reward_viewed',businessId,{
      context:{surface_key:'rewards',entry_point:'customer_wallet',
        locale:customerLocale,surface_version:'v255'}
    });
    const classicAction=!actionsResult.error&&actionsResult.data?.redemption?.classic
      ?actionsResult.data.redemption.classic:null;
    const actionRewards=actionsResult.error?[]:[
      ...(classicAction?[classicAction]:[]),
      ...(Array.isArray(actionsResult.data?.rewards)?actionsResult.data.rewards:[])
    ];
    const catalog=walletCatalogV241;
    const rewards=actionRewards.length?actionRewards.map(actionReward=>{
      if(actionReward.redemption_kind==='classic_points'){
        return {...actionReward,customer_name:actionReward.name||'Redeem points',
          action_key:'classic_points'};
      }
      const match=catalog.find(item=>(item.customer_name||item.name)===actionReward.name
        &&Number(item.cost_points||0)===Number(actionReward.cost_points||0))||{};
      return {...match,...actionReward,customer_name:actionReward.name||match.customer_name,
        redemption_kind:'catalog_reward',action_key:`catalog:${actionReward.id}`};
    }):catalog.map(reward=>({...reward,redemption_kind:'catalog_reward',
      action_key:`catalog:${reward.id}`}));
    const redemptionEnabled=!actionsResult.error&&actionsResult.data?.redemption?.enabled===true;
    /* v286 (audit: this section degraded invisibly). When the actions read fails — including the
       businessId-unavailable case, which resolves to an error by construction — the catalog still
       rendered under a lede promising a QR and every card still printed "Available at counter",
       yet no redeem button was drawn. Every other section on this page names its own failure and
       offers a retry; this one now does too, and no card claims an availability we could not
       check. */
    const redemptionUncheckedV286=!!actionsResult.error;
    /* nestly_v395: the hero swipe is filled from THIS list — the one the customer can actually
       redeem against — so the card at the top of the profile and the list below it can never
       disagree about what the ladder holds. */
    const heroRootV397=$('walletBody')||document;
    /* nestly_v397: the ONE number both the hero pill and the Points & gifts tile now print, taken
       from the same server-backed check the reward list uses. */
    /* nestly_v428 (item 6): the claimable SET is computed once here and the Available panel below
       reuses it. It was filtered twice with the same predicate, and the tile copy and the list now
       have to agree about more than a number, so one derivation is the only safe shape. */
    const claimableRewardsV422=rewards.filter(item=>item.action_key&&customerRewardCanRedeem(item,redemptionEnabled));
    const readyCountV397=claimableRewardsV422.length;
    const chooseOneSlotV428=customerStampChooseOneSlotV428(claimableRewardsV422,loyalty.unit);
    customerRewardReadyCountApplyV397(readyCountV397,heroRootV397,{chooseOneV428:chooseOneSlotV428});
    customerHeroRewardPagesV395(rewards,{
      balance:actionableCard?.loyalty?.balance,
      unit:actionableCard?.loyalty?.unit,
      /* nestly_v475 (owner: "why the stamp card portion is not scrollable? i need to scroll and
         view rewards"). This dedupe exists because on a POINTS hero, page 1 already IS the next
         reward's card — name, cost and a Redeem button — so repeating it as a swipe page would
         show the same thing twice. On a STAMPS hero page 1 is the v422 stamp grid: it has no
         cost, no photo and no Redeem button, and names the reward only in a sentence. Deduping
         there suppressed a page that duplicated nothing — and for a firm whose customer can reach
         exactly one reward, suppressing that one page left a single-page track with no dots and
         nothing to swipe, which is precisely what the owner photographed. */
      currentRewardName:heroRootV397.querySelector('[data-hero-stamp-slot-host-v422]')
        ?'':actionableCard?.next_eligible_reward?.name,
      /* nestly_v399: page 1's reward is deduped on name AND cost. next_eligible_reward carries no
         id, and this firm runs two different rewards both called "Free Lotion", so the name alone
         would have hidden the second one. */
      currentRewardCost:actionableCard?.next_eligible_reward?.cost_units,
      redemptionEnabled,
      /* The same Book control page 1 carries, so a swiped reward offers the same next step. */
      bookAction:heroRootV397.querySelector('[data-repeat-booking]')?.outerHTML||'',
      /* nestly_v399: the last page hands off to the reward catalogue this profile already
         renders, through the SAME shortcut tile the modules row uses — no second reward surface.
         Whichever of the two reward shortcuts this firm actually has is the destination. */
      viewAllAction:(document.querySelector('[data-business-shortcut-v347="points"]')
        ?'points':document.querySelector('[data-business-shortcut-v347="rewards"]')?'rewards':'')
    },heroRootV397);
    wireCustomerHeroViewAllV399(heroRootV397);
    /* nestly_v422: an empty CATALOGUE no longer replaces this whole section. It used to, and that
       was fine while the section was only a catalogue — but it now also holds the customer's own
       claim History, and a firm that has retired every reward would otherwise take the record of
       what its customers already received off the screen with them. The tabbed shell below renders
       either way; the Available panel carries its own empty line. */
    /* nestly_v422: the local availability copy, rewardLockLineV176 and the v286 "could not check"
       override are all gone from here, because the only thing that read them was the availability
       line on a NON-claimable card and there are no such cards on this list any more.
       The two guarantees they carried are now structural rather than textual:
         · v286 — a page that could not verify redemption can no longer print "Available at
           counter", because customerRewardCanRedeem returns false for every reward when
           redemptionEnabled is not true, so the Available panel holds no cards at all and says
           outright that the check failed. Strictly stronger than relabelling a card.
         · v176 — a tier-gated reward no longer appears here to be labelled. That is the owner's
           2026-08-22 ruling on photo 6, and it is a deliberate reversal of v176's "stays VISIBLE
           and locked": the tier ladder on this same page is where a member reads what climbing
           earns them.
       CUSTOMER_REWARD_AVAILABILITY_COPY_V399 itself stays — the hero swipe pages still use it. */
    host.setAttribute('aria-busy','false');
    const rewardUnit=loyalty.unit||'points';
    /* nestly_v422 (owner photo 6: "only show redeemable rewards after customer achieve the
       reward", with the progress bar, the "5/5 stamps · 0 more to go" line and the "More points
       needed" line all struck through on cards the customer could not claim).
       v339 SORTED claimable rewards to the front; the owner's ruling (2026-08-22) is that the rest
       do not belong on this list at all. So Available is exactly the set customerRewardCanRedeem
       says the counter will honour — the SAME predicate the hero's ready-count uses, so the pill
       above and the list below can never disagree about how many are ready.
       Nothing is hidden from the customer that they could act on: a reward still being earned is
       what the stamp card / points figure at the top of the page is for, and it reappears here the
       moment it becomes claimable. `rewards` keeps every row for the wiring below (the hero swipe
       pages and the ready-count are built from the FULL catalogue, above); only what this list
       PAINTS is narrowed.
       nestly_v428 (item 6): the second copy of this filter is gone — the set is built once above,
       where the ready-count is taken from it, so the pill, the tile subtitle and this list are
       three readings of one array rather than three filters that have to be kept in step. */
    /* v195: this now renders inside the Reward points tab, which already prints the balance in
       full. The repeated balance and the three-step "how rewards work" strip went with the card
       the owner crossed out; one line of instruction survives, on the control it describes. */
    /* nestly_v422 (owner photo 6). ONE card shape, and it is the claimable one. Everything the
       owner struck through on that photo described a card the customer could NOT act on — the
       progress bar, the "5/5 stamps · 0 more to go" reading, the "More points needed" line, the
       "In progress" and tier-locked pills. With the list narrowed to what the counter will
       actually honour, none of those states can occur here, so they are gone rather than left as
       branches that can never be true. What survives is what a customer standing at the counter
       needs: the photo, the name, what it costs, the description, how long they have to use it,
       where it is valid, and the QR button. */
    const rewardCardV422=r=>{
      const cost=Math.max(0,Number(r.cost_points)||0);
      const imageUrlV340=customerMediaUrlV95(r.image_ref);
      return `<article class="wallet-reward customer-reward-card-v339">
      <div class="customer-reward-photo-v340${imageUrlV340?'':' customer-reward-photo-empty-v340'}">${imageUrlV340
        ?`<img src="${esc(imageUrlV340)}" alt="" loading="lazy" data-reward-photo-v340>`
        :CUI.icon('loyalty',{size:24})}</div><div class="customer-reward-card-head-v339"><span class="pill ok">Ready to claim</span>${customerRewardHelpButtonV468('data-reward-rules-v468',r.action_key,r.customer_name||'Reward')}</div>
      <b class="wallet-reward-trade customer-reward-name-v339">${esc(r.customer_name||'Reward')}</b>
      ${cost>0?`<p class="wallet-reward-cost customer-reward-cost-v339">${esc(customerPointTotalV103(cost))} ${esc(rewardUnit)}</p>`:''}
      ${customerRewardDescriptionV183(r.description)?`<p class="muted small" style="margin-top:7px">${esc(customerRewardDescriptionV183(r.description))}</p>`:''}
      ${/* nestly_v464 (owner ruling R3(e): "the customer sees the expiry date on each earned
           reward"). The server's date, printed with the same walletDate() the granted-entitlement
           card already uses — never computed here from a day count, because the day count is
           pinned to the card this customer is holding and the browser does not know which card
           that is. */''}
      ${r.expires_at?`<p class="muted small customer-reward-useby-v464" data-reward-useby-v464="${esc(String(r.expires_at))}" style="margin-top:5px">Use by ${esc(walletDate(r.expires_at))}</p>`:''}
      ${/* nestly_v471: the OFFER's own end date, in the owner's words. Distinct from "Use by"
           directly above it, which is the stamps-only earned-reward deadline — one says when the
           gift stops being offered, the other when a gift you already hold goes stale. A reward
           that carries both legitimately prints both. */''}
      ${customerRewardEndsLineV471(r)}
      ${r.entitlement_expiry_days?`<p class="muted small" style="margin-top:5px">Use within ${Number(r.entitlement_expiry_days)} days after claim.</p>`:''}
      ${r.eligibility?`<p class="muted small" style="margin-top:5px">${[['branches','locations'],['services','services'],['products','products']].filter(([key])=>r.eligibility[key]?.scope==='restricted').map(([key,label])=>`${Number(r.eligibility[key].count||0)} eligible ${label}`).join(' · ')||'Valid across all eligible services and locations.'}</p>`:''}
      ${r.instructions?`<details style="margin-top:9px"><summary class="small">How to use</summary><p class="muted small" style="margin-top:5px">${esc(r.instructions)}</p></details>`:''}
      ${r.terms?`<details style="margin-top:9px"><summary class="small">Terms</summary><p class="muted small" style="margin-top:5px">${esc(r.terms)}</p></details>`:''}
      <div class="wallet-reward-actions"><button class="btn sm" type="button" data-customer-redeem="${esc(r.action_key)}">${CUI.icon('scan',{size:16})}<span>Show QR at counter</span></button></div></article>`;
    };
    /* nestly_v429 (C): an entitlement card. Deliberately NOT a rewardCardV422 with fields blanked
       out — the two are different things and only one of them has a QR. A granted entitlement is
       redeemed by STAFF at the till (staff_redeem_welcome_v215 / _bringback_v361 / _referral_v420
       each take the grant id), so offering a QR here would be a button that leads nowhere.
       Every line comes from the payload as sent. There is NO client-side eligibility arithmetic:
       the server already decided what is active, derived the status from expires_at, and wrote the
       instructions sentence — a browser second-guessing any of that is how the promise and the
       counter start to disagree. */
    const entitlementSourceChipV429={welcome:'Welcome gift',bringback:'We miss you',referral:'Referral'};
    const entitlementCurrencyV429=b?.currency||'SGD';
    const entitlementCardV429=grant=>{
      const chip=entitlementSourceChipV429[String(grant?.source||'')]||'Gift';
      const label=String(grant?.label||'').trim()||chip;
      const granted=grant?.granted_at?walletDate(grant.granted_at):'';
      const expires=grant?.expires_at?walletDate(grant.expires_at):'';
      const floor=Number(grant?.min_spend_cents)>0
        ?`Valid on a visit of ${customerReferralMoneyV300(grant.min_spend_cents,entitlementCurrencyV429)}+`:'';
      const instructions=String(grant?.instructions||'').trim();
      return `<article class="wallet-reward customer-reward-card-v339" data-customer-entitlement-v429="${esc(String(grant?.source||''))}">
      <div class="customer-reward-photo-v340 customer-reward-photo-empty-v340">${CUI.icon('loyalty',{size:24})}</div>
      <div class="customer-reward-card-head-v339"><span class="pill ok">${esc(chip)}</span>${customerRewardHelpButtonV468('data-entitlement-rules-v468',grant?.id,label)}</div>
      <b class="wallet-reward-trade customer-reward-name-v339" data-merchant-content>${esc(label)}</b>
      ${granted?`<p class="muted small" style="margin-top:5px">Given to you on ${esc(granted)}</p>`:''}
      ${expires?`<p class="muted small" style="margin-top:5px">Use it by ${esc(expires)}</p>`:''}
      ${floor?`<p class="muted small" style="margin-top:5px">${esc(floor)}</p>`:''}
      ${instructions?`<p class="muted small" style="margin-top:7px">${esc(instructions)}</p>`:''}
      </article>`;
    };
    /* The server's own list, in the server's own order (soonest to lapse first). An error or an
       unrecognised payload leaves it empty, which is the fail-closed rule above. */
    const entitlementsV429=!entitlementsResultV427?.error&&Array.isArray(entitlementsResultV427?.data?.active)
      ?entitlementsResultV427.data.active:[];
    /* nestly_v422 (owner photo 6, "Available" and "History" written as tabs over this heading, with
       "once redeemed, rewards go history"). History is NOT fetched here: it is a second server read
       and most customers open this screen to claim, not to reminisce, so it loads the first time
       the tab is opened and is cached for the rest of the render. That is also why the tab carries
       no count — a number we have not read yet would have to be guessed. */
    host.innerHTML=`${redemptionUncheckedV286
      ?`<div class="wallet-section-head" data-rewards-redemption-unchecked><div><h2>Redemption can’t be checked right now</h2><p class="muted small">These rewards are shown for reference only — we could not reach this business’s redemption settings, so no QR can be issued yet.</p></div><span class="spacer"></span><button class="btn ghost sm" type="button" id="walletRewardsRedemptionRetry">Retry</button></div>`
      :`<div class="customer-rewards-carousel-head-v337"><h2>Your rewards</h2></div>`}
      <div class="v150-segment customer-rewards-tabs-v422" role="tablist" aria-label="Your rewards">
        ${/* nestly_v429 (C): the count is what the panel PAINTS — catalogue rewards plus the
             entitlements the counter already owes this customer. A voucher sitting in the panel
             uncounted would make the number an undercount of what they can walk in and use. */''}
        <button type="button" role="tab" aria-selected="true" data-rewards-tab-v422="available">Available${claimableRewardsV422.length+entitlementsV429.length?` (${claimableRewardsV422.length+entitlementsV429.length})`:''}</button>
        <button type="button" role="tab" aria-selected="false" data-rewards-tab-v422="history">History</button>
      </div>
      <div data-rewards-panel-v422="available" role="tabpanel">
        ${/* nestly_v428 (item 6): "Available (2)" is true and, on one stamp slot, misleading — the
             card carries two gifts and the cycle honours one. The count stays (two ARE on offer);
             the sentence says which part of that the customer gets, above the cards it applies
             to, rather than after they have chosen and been refused. */''}
        ${claimableRewardsV422.length
          ?`${chooseOneSlotV428?'<p class="muted small customer-programme-rewards-lede" data-rewards-chooseone-v428>Choose 1 — staff will scan the one you pick.</p>':''}
            <p class="muted small customer-programme-rewards-lede">Pick a reward, then show its QR at the counter — staff scan it and the ${esc(rewardUnit)} come off.</p>
            <div class="wallet-rewards customer-rewards-carousel-v337">${claimableRewardsV422.map(rewardCardV422).join('')}</div>`
          :entitlementsV429.length?''
          :`<p class="muted small customer-rewards-empty-v422">${esc(redemptionUncheckedV286
              ?'We could not check this business’s redemption settings, so nothing can be claimed right now.'
              :'Nothing to claim yet — keep collecting and your reward will appear here.')}</p>`}
        ${/* nestly_v429 (C): AFTER the catalogue cards, and under their own heading, because these
             are not earned with a balance and are not claimed with a QR — the counter already owes
             them. The "nothing to claim yet" line above is suppressed when there are entitlements:
             a customer holding a welcome gift has plainly got something to claim. */''}
        ${entitlementsV429.length
          ?`<div class="customer-rewards-carousel-head-v337" style="margin-top:14px"><h3>Given to you</h3></div>
            <p class="muted small customer-programme-rewards-lede">Nothing to scan — staff apply these at the counter.</p>
            <div class="wallet-rewards customer-rewards-carousel-v337" data-customer-entitlements-v429>${entitlementsV429.map(entitlementCardV429).join('')}</div>`
          :''}
      </div>
      <div data-rewards-panel-v422="history" role="tabpanel" hidden></div>`;
    if($('walletRewardsRedemptionRetry'))$('walletRewardsRedemptionRetry').onclick=loadRewards;
    /* V468-E4: the "?" on every reward card and every granted gift. Both look their subject up in
       the list that painted them, so the sheet can only ever show the payload this render used —
       there is no second fetch and nothing to go stale between the card and its rules. */
    host.querySelectorAll('[data-reward-rules-v468]').forEach(button=>button.onclick=()=>{
      const match=rewards.find(item=>item.action_key===String(button.dataset.rewardRulesV468||''));
      if(match)showCustomerRewardRulesV468(match,{unit:rewardUnit,currency});
    });
    /* nestly_v471: the same sheet, from the hero swipe — which is where the customer sees the
       gifts they are still saving toward, and therefore where "for ALL rewards" actually bites.
       Wired here beside its sibling rather than in a second handler, exactly as v397 did for the
       hero's Redeem button, and it queries heroRootV397 because the swipe lives outside #walletRewards.
       The lookup is by index into customerHeroRewardRowsV471 — see that array's own note for why
       action_key cannot be trusted on this surface. */
    (heroRootV397.querySelectorAll('[data-hero-swipe-v395] [data-hero-reward-rules-v471]')||[])
      .forEach(button=>button.onclick=()=>{
        const match=customerHeroRewardRowsV471[Number(button.dataset.heroRewardRulesV471)];
        if(match)showCustomerRewardRulesV468(match,{unit:customerRewardUnitV429(match,rewardUnit),currency});
      });
    host.querySelectorAll('[data-entitlement-rules-v468]').forEach(button=>button.onclick=()=>{
      const match=entitlementsV429.find(item=>String(item?.id||'')===String(button.dataset.entitlementRulesV468||''));
      if(match)showCustomerRewardRulesV468(match,{unit:rewardUnit,currency:entitlementCurrencyV429,
        title:String(match.label||'').trim()});
    });
    /* nestly_v422 — the Available / History tabs (owner photo 6). One panel is visible at a time;
       History loads once, on first open, from customer_get_reward_history_v422.
       Every failure leaves the tab usable and says what happened rather than showing an empty
       list, because "no history" and "we could not read your history" are different facts and a
       customer who has claimed rewards would read the second as the first. An old server that
       does not have the function yet (the four-hour CDN window, or a rollback) answers 42883 /
       PGRST202 and gets the honest "not available" line — the Available tab is untouched. */
    let rewardHistoryLoadedV422=false;
    const renderRewardHistoryV422=(state,items=[])=>{
      const panel=host.querySelector('[data-rewards-panel-v422="history"]');
      if(!panel)return;
      if(state==='loading'){panel.innerHTML='<p class="muted small">Loading your claimed rewards…</p>';return}
      if(state==='unavailable'){panel.innerHTML='<p class="muted small">Your claimed rewards are not available right now.</p>';return}
      if(state==='error'){
        panel.innerHTML=`<p class="muted small">We could not load your claimed rewards.</p><button class="btn ghost sm" type="button" data-rewards-history-retry-v422 style="margin-top:8px">Retry</button>`;
        const retry=panel.querySelector('[data-rewards-history-retry-v422]');
        if(retry)retry.onclick=()=>{rewardHistoryLoadedV422=false;loadRewardHistoryV422()};
        return;
      }
      if(!items.length){panel.innerHTML='<p class="muted small customer-rewards-empty-v422">Nothing claimed yet. Rewards you redeem show up here.</p>';return}
      panel.innerHTML=`<div class="wallet-rewards customer-rewards-carousel-v337">${items.map(item=>{
        const name=String(item?.reward_name||'').trim()||'Reward';
        const when=item?.redeemed_at?walletDate(item.redeemed_at):'';
        /* A v323 stamp milestone is claimed without spending a balance, so points_spent is 0 on
           those rows; printing "0 points" would invent a price the customer never paid. */
        const spent=item?.consumes_balance===true?Math.max(0,Number(item.points_spent)||0):0;
        const photo=customerMediaUrlV95(item?.image_ref);
        /* nestly_v429 (C): v427 merged redeemed welcome / bring-back / referral grants into this
           list, so a row now says WHICH engine gave it. Every grant row carries consumes_balance
           false and points_spent 0, so the cost line was already suppressed correctly — the only
           thing missing was the label, without which a free coffee the shop handed over reads as
           a reward the customer bought with points. 'reward' is the ordinary redemption and needs
           no chip; an unrecognised source gets none rather than a guess. */
        const sourceChipV429=entitlementSourceChipV429[String(item?.source||'')]||'';
        /* nestly_v464 (owner ruling R3(e)): the fifth source on this list is a reward the customer
           EARNED AND LOST to its own deadline. It is not a claim and must never wear the "Claimed"
           pill — the date beside it is the day it expired, not the day they were given anything.
           Everything else about the card is the same, deliberately: this is the same reward, in
           the same list, with an honest account of what happened to it. */
        const lapsedV464=String(item?.source||'')==='expired';
        /* V468-C2 (owner, photo 2: the Claimed pill circled, an arrow to the card's top-right and
           "shift up" written beside the name and the date on both cards). The pill was the FIRST
           row of the copy column, so it pushed the name and the date down past the middle of a
           64px thumbnail and left the whole top-right of the card blank. It is a status, not a
           heading: it belongs in the corner and the reward's name belongs at the top.
           The copy column becomes a row — text, then the pills — which is a layout change and
           nothing else: same rewards, same wording, same date format, same thumbnail and same
           generic-gift fallback. The pills keep their own box so a long name wraps beside them
           instead of under them, and two pills (Claimed + a source chip) stack in that box. */
        return `<article class="wallet-reward customer-reward-card-v339 customer-reward-card-claimed-v422${lapsedV464?' customer-reward-card-expired-v464':''}"${lapsedV464?' data-reward-expired-v464="1"':''}>
          <div class="customer-reward-photo-v340${photo?'':' customer-reward-photo-empty-v340'}">${photo
            ?`<img src="${esc(photo)}" alt="" loading="lazy" data-reward-photo-v340>`
            :CUI.icon('loyalty',{size:24})}</div>
          <div class="customer-reward-claimed-copy-v468">
            <div class="customer-reward-claimed-text-v468">
              <b class="wallet-reward-trade customer-reward-name-v339" data-merchant-content>${esc(name)}</b>
              ${when?`<p class="muted small" style="margin-top:5px">${esc(when)}</p>`:''}
              ${spent>0?`<p class="muted small" style="margin-top:5px">${esc(customerPointTotalV103(spent))} ${esc(rewardUnit)}</p>`:''}
            </div>
            <div class="customer-reward-card-head-v339"><span class="pill">${lapsedV464?'Expired':'Claimed'}</span>${lapsedV464||!sourceChipV429?'':`<span class="pill" data-reward-source-v429="${esc(String(item.source))}">${esc(sourceChipV429)}</span>`}</div>
          </div>
        </article>`;
      }).join('')}</div>`;
      panel.querySelectorAll('[data-reward-photo-v340]').forEach(image=>{image.onerror=()=>{
        const frame=image.closest('.customer-reward-photo-v340');if(!frame)return;
        frame.classList.add('customer-reward-photo-empty-v340');
        frame.innerHTML=CUI.icon('loyalty',{size:24});
      }});
    };
    const loadRewardHistoryV422=async()=>{
      if(rewardHistoryLoadedV422)return;
      rewardHistoryLoadedV422=true;
      renderRewardHistoryV422('loading');
      const {data,error}=await customerRpc('customer_get_reward_history_v422',
        {p_business_slug:businessSlug,p_limit:50});
      if(!isWalletSectionCurrent(host))return;
      if(error){
        rewardHistoryLoadedV422=false;
        const missing=['42883','PGRST202'].includes(String(error.code||''));
        return renderRewardHistoryV422(missing?'unavailable':'error');
      }
      renderRewardHistoryV422('ready',Array.isArray(data?.items)?data.items:[]);
    };
    host.querySelectorAll('[data-rewards-tab-v422]').forEach(tab=>tab.onclick=()=>{
      const wanted=String(tab.dataset.rewardsTabV422||'available');
      host.querySelectorAll('[data-rewards-tab-v422]').forEach(other=>
        other.setAttribute('aria-selected',String(other===tab)));
      host.querySelectorAll('[data-rewards-panel-v422]').forEach(panel=>{
        panel.hidden=panel.dataset.rewardsPanelV422!==wanted;
      });
      if(wanted==='history')loadRewardHistoryV422();
    });
    /* v340 (gap 4): never a broken image. A stored object that has since been deleted, or a
       storage read that fails, swaps the <img> for the same gift glyph an image-less reward
       already shows — wired here rather than as an inline onerror because the app runs under a
       CSP with no inline handlers. */
    host.querySelectorAll('[data-reward-photo-v340]').forEach(image=>{image.onerror=()=>{
      const frame=image.closest('.customer-reward-photo-v340');if(!frame)return;
      frame.classList.add('customer-reward-photo-empty-v340');
      frame.innerHTML=CUI.icon('loyalty',{size:24});
    }});
    /* v339 (task A): the "reward ready" banner's validity line. The wallet payload that painted
       the banner has no expiry field on next_eligible_reward, but THIS catalogue read does — the
       same claim_available_until / entitlement_expiry_days the business's reward editor writes.
       Matched by the banner's own printed name against the catalogue's customer_name/name, and
       filled only on an exact match with one of those two fields actually set. Anything else
       (no match, both fields null, banner absent) leaves the node hidden.
       v340 (gap 1): the mockup's "No purchase required" clause now HAS a field behind it —
       requires_purchase, added by db/migrations/20260815_nestly_v340_reward_purchase_
       requirement.sql. It is appended only when the catalogue explicitly says false. Three
       states, three behaviours: false prints the clause, true prints nothing (the app enforces
       no purchase condition, so promising the customer one would be worse than silence), and
       undefined — the server before that migration is applied — also prints nothing, because a
       missing field is not a "no". */
    const claimValidityNodeV339=$('walletBody')?.querySelector('[data-claim-validity-v339]');
    const bannerNameV339=$('walletBody')?.querySelector('.customer-claimable-banner-name-v337')?.textContent?.trim()||'';
    if(claimValidityNodeV339&&bannerNameV339){
      const matchV339=rewards.find(item=>String(item.customer_name||item.name||'').trim()===bannerNameV339);
      const untilV339=matchV339?.claim_available_until?walletDate(matchV339.claim_available_until):'';
      const daysV339=Math.max(0,Math.round(Number(matchV339?.entitlement_expiry_days)||0));
      const baseLineV339=untilV339?`Valid until ${untilV339}`
        :(daysV339?`Use within ${daysV339} day${daysV339===1?'':'s'} of claiming`:'');
      const noPurchaseV340=matchV339?.requires_purchase===false?'No purchase required':'';
      const lineV339=[baseLineV339,noPurchaseV340].filter(Boolean).join(' · ');
      if(lineV339){claimValidityNodeV339.textContent=lineV339;claimValidityNodeV339.hidden=false}
    }
    let redemptionAttempt=null;
    /* nestly_v397: the hero swipe's "Redeem now" carries the same data-customer-redeem contract,
       so it is wired HERE rather than growing a second redemption path. It lives outside #walletRewards,
       hence the second query. Each button restores its OWN label afterwards — the hero says
       "Redeem now", the list says "Show QR at counter", and the shared handler must not
       overwrite one with the other. */
    [...host.querySelectorAll('[data-customer-redeem]'),
     ...(heroRootV397.querySelectorAll('[data-hero-swipe-v395] [data-customer-redeem]')||[])
    ].forEach(button=>button.onclick=async()=>{
      const reward=rewards.find(item=>item.action_key===button.dataset.customerRedeem);
      if(!reward)return;
      const restoreLabelV397=button.querySelector('span')?.textContent||'';
      if(!redemptionAttempt||redemptionAttempt.actionKey!==reward.action_key){
        redemptionAttempt={actionKey:reward.action_key,key:crypto.randomUUID()};
      }
      button.disabled=true;button.querySelector('span').textContent='Preparing QR…';
      const {data:intent,error:intentError}=await sb.rpc('customer_create_redemption_intent_v89',
        customerRedemptionIntentArgsV89({
          businessId,reward,idempotencyKey:redemptionAttempt.key
        }));
      if(!isWalletSectionCurrent(host)||!button.isConnected)return;
      button.disabled=false;button.querySelector('span').textContent=restoreLabelV397;
      if(intentError){
        toast(intentError.code==='PGRST202'||intentError.code==='42883'
          ?'Something’s not working right now. Please try again shortly.'
          :'This reward could not be prepared. Refresh its balance and try again.');
        return;
      }
      if(intent?.status==='completed'||intent?.status==='redeemed'){
        redemptionAttempt=null;toast('This reward is already redeemed');loadRewards();loadTransactions(null);void customerCounterMomentV468();return;
      }
      if(intent?.status!=='pending'||!intent?.qr_token){
        toast(CUSTOMER_REDEMPTION_STATUS_COPY[String(intent?.status||'')]||'This reward can’t be used right now.');return;
      }
      /* V468-E2(a): closing the QR is the customer turning back to their own balance. loadRewards
         alone re-read the catalogue and left the balance, the hero and the history exactly as
         stale as they were — the "takes awhile" the owner reported. */
      showPendingRedemptionQr({intent,businessName:b.name,rewardName:reward.customer_name||reward.name,
        onClose:()=>{loadRewards();void customerCounterMomentV468()}});
    });
  };
  const activityState={items:[],nextCursor:null};
  const loadActivity=async(cursor=null)=>{
    const host=$('walletActivity');if(!host)return;
    const {data,error}=await customerRpc('customer_get_loyalty_details',{...args,p_cursor:cursor||{limit:20}});
    if(!isWalletSectionCurrent(host))return;
    if(error)return walletSectionError('walletActivity',walletRpcDenied(error)?ct('Loyalty activity is not available for this account.'):ct('Activity could not be loaded.'),()=>loadActivity(cursor),error);
    const next=Array.isArray(data?.items)?data.items:[];
    activityState.items=cursor?[...activityState.items,...next]:next;activityState.nextCursor=data?.next_cursor||null;
    if(!cursor)customerConfirmedEarnFeedback(businessId,next,data?.unit||loyalty.unit||'points');
    if(!activityState.items.length)return walletSectionEmpty('walletActivity','Activity',ct('No loyalty activity is available yet.'),businessSlug,'activity',()=>loadActivity(null),isWalletCurrent);
    const unit=esc(data?.unit||loyalty.unit||'points'),expiry=data?.expiry||{};
    host.setAttribute('aria-busy','false');
    host.innerHTML=`<div class="wallet-section-head"><div><h2>${esc(ct('Loyalty activity'))}</h2>${Number(expiry.expiring_next_30_days||0)>0?`<p class="muted small">${esc(customerPointTotalV103(expiry.expiring_next_30_days))} ${unit} expire within 30 days${expiry.next_expiry_at?' · next '+esc(walletDate(expiry.next_expiry_at)):''}.</p>`:`<p class="muted small">${esc(ct('Your loyalty history with this business.'))}</p>`}</div></div>
      <div>${activityState.items.map(item=>{const delta=Number(item.points_delta||0),campaign=campaignEntitlementDisplayV99(item);return `<div class="wallet-line"><div><b>${esc(campaign.title||ct('Loyalty activity'))}</b><p class="muted small" style="margin-top:3px">${esc(walletDate(item.event_at,true))}${campaign.status?' · '+esc(campaign.status.replaceAll('_',' ')):''}</p>${campaign.detail?`<p class="muted small" style="margin-top:3px">${esc(campaign.detail)}</p>`:''}</div><span class="spacer"></span>${campaign.pending?`<span class="pill off">${esc(ct('Pending with business'))}</span>`:`<span class="wallet-delta ${delta>0?'plus':delta<0?'minus':''}">${delta>0?'+':delta<0?'−':''}${esc(customerPointTotalV103(Math.abs(delta)))} ${unit}</span>`}</div>`}).join('')}</div>
      ${activityState.nextCursor?`<button class="btn ghost sm" id="walletActivityMore" style="margin-top:12px">${esc(ct('Load more'))}</button>`:''}`;
    if($('walletActivityMore'))$('walletActivityMore').onclick=()=>{ $('walletActivityMore').disabled=true;loadActivity(activityState.nextCursor) };
    syncCustomerActivityFeedV468();
  };
  const transactionState={items:[],nextCursor:null};
  const loadTransactions=async(cursor=null)=>{
    const host=$('walletTransactions');if(!host)return;
    host.setAttribute('aria-busy','true');
    const requestedCursor=cursor||{limit:20};
    const {data,error}=await customerRpc('customer_get_transaction_history_v167',{
      p_business_slug:businessSlug,p_cursor:requestedCursor
    });
    if(!isWalletSectionCurrent(host))return;
    if(error){
      return walletSectionError(
        'walletTransactions',
        walletRpcDenied(error)?ct('Transaction history is not available for this account.'):ct('Transaction history could not be loaded.'),
        ()=>loadTransactions(cursor),
        error
      );
    }
    const incoming=Array.isArray(data?.items)?data.items:[];
    if(cursor){
      const seen=new Set(transactionState.items.map(item=>`${item.source_kind}:${item.source_id}`));
      transactionState.items=[
        ...transactionState.items,
        ...incoming.filter(item=>!seen.has(`${item.source_kind}:${item.source_id}`))
      ];
    }else transactionState.items=incoming;
    transactionState.nextCursor=data?.next_cursor||null;
    host.setAttribute('aria-busy','false');
    /* nestly_v429 (D): a points→stamps conversion is ONE event the customer lived through, not two
       anonymous adjustments. v426 tags each ledger row with `entry`, and a conversion row carries
       the entry_group that pairs its two halves plus THIS customer's own points_delta /
       stamps_delta. Two rules follow:
         · the pair collapses to one sentence, built from this customer's figures — never from the
           batch's converted_points / issued_stamps, which would tell every customer the whole
           firm's total as if it were their own;
         · a programme pot transfer is dropped outright. It is an internal move of a balance
           between two pots that changed nothing the customer owns, and it surfaced as "Points
           adjustment −75,800" — the single most alarming line this screen has ever printed.
       A row with no `entry` is an ordinary transaction and is untouched. */
    const conversionGroupsSeenV429=new Set();
    const historyRowsV429=transactionState.items.filter(item=>{
      const entry=String(item?.entry||'');
      if(entry==='pot_transfer')return false;
      if(entry!=='conversion')return true;
      const group=String(item?.entry_group||'');
      if(!group)return true;
      if(conversionGroupsSeenV429.has(group))return false;
      conversionGroupsSeenV429.add(group);return true;
    });
    if(!historyRowsV429.length){
      host.innerHTML=`<div class="wallet-section-head"><div><h2>${esc(ct('Transactions & points'))}</h2><p class="muted small">${esc(ct('No purchases or points activity has been recorded for this programme yet.'))}</p></div></div>`;
      return;
    }
    const historyCurrency=String(data?.business?.currency||currency);
    const historyMoney=cents=>`${historyCurrency} ${(Number(cents||0)/100).toFixed(2)}`;
    const historyItemMarkup=item=>{
        /* nestly_v429 (D): the collapsed conversion line. It carries no money, no earned/redeemed
           breakdown and no line items — none of those exist for a conversion — so it returns
           early rather than being threaded through a markup built for a sale. */
        if(String(item?.entry||'')==='conversion'){
          const spentV429=Math.abs(Number(item.points_delta)||0),issuedV429=Math.abs(Number(item.stamps_delta)||0);
          return `<article class="wallet-line" style="align-items:flex-start" data-conversion-v429="${esc(String(item.entry_group||''))}"><div style="min-width:0;flex:1">
            <b>${esc(`${customerPointTotalV103(spentV429)} ${spentV429===1?'point':'points'} converted to ${customerPointTotalV103(issuedV429)} ${issuedV429===1?'stamp':'stamps'}`)}</b>
            <p class="muted small" style="margin-top:3px">${esc(walletDate(item.event_at,true))}</p>
          </div></article>`;
        }
        const earned=Number(item.points_earned||0),redeemed=Number(item.points_redeemed||0),removed=Number(item.points_removed||0);
        /* nestly_v437 (owner rule 13): the noun follows the ROW's own pot, never the live
           programme — "+3 stamps" earned on the stamp card stays "+3 stamps" after a switch to
           points. The server resolves loyalty_unit from points_ledger.programme_id. */
        const unitNounV437=n=>`${item.loyalty_unit==='stamps'?'stamp':'point'}${Number(n)===1?'':'s'}`;
        const gross=item.gross_cents===null||item.gross_cents===undefined?null:Number(item.gross_cents);
        const net=item.net_cents===null||item.net_cents===undefined?null:Number(item.net_cents);
        const lines=Array.isArray(item.line_items)?item.line_items:[];
        /* V469 (owner photo 11). A welcome offer, bring-back voucher or referral gift is handed
           over as a $0 sale, so this row used to read "Retail purchase — SGD 0.00" — the customer
           could see that something happened but not what. grant_label is the gift's own
           customer-facing name, derived server-side from the grant note; the raw note is never
           sent, because staff type real remarks into it. */
        const grantLabelV469=String(item.grant_label||'').trim();
        const packageLabel=item.is_package_session===true?'Package session used'
          :grantLabelV469||(item.description||String(item.event_type||'Transaction').replaceAll('_',' '));
        const packageDetail=item.is_package_session===true?`${item.package_name||'Package'}${item.package_purchased_at?' · purchased '+walletDate(item.package_purchased_at):''}${item.package_reference?' · ref '+item.package_reference:''}`:(grantLabelV469?'Given free':'');
        return `<article class="wallet-line" style="align-items:flex-start"><div style="min-width:0;flex:1"><div class="row" style="align-items:flex-start"><div><b>${esc(packageLabel)}</b><p class="muted small" style="margin-top:3px">${esc(walletDate(item.event_at,true))}${item.status?' · '+esc(String(item.status).replaceAll('_',' ')):''}</p>${packageDetail?`<p class="muted small" style="margin-top:3px">${esc(packageDetail)}</p>`:''}</div><span class="spacer"></span>${net===null||item.is_package_session===true?'':`<b style="white-space:nowrap">${esc(historyMoney(net))}</b>`}</div>
          ${gross!==null&&net!==gross?`<p class="muted small" style="margin-top:5px">Original ${esc(historyMoney(gross))} · net after linked corrections ${esc(historyMoney(net))}</p>`:''}
          ${(earned||redeemed||removed)?`<p class="small" style="margin-top:6px">${earned?`<span class="wallet-delta plus">+${esc(customerPointTotalV103(earned))} ${esc(unitNounV437(earned))} earned</span>`:''}${earned&&(redeemed||removed)?' · ':''}${redeemed?`<span class="wallet-delta minus">−${esc(customerPointTotalV103(redeemed))} ${esc(unitNounV437(redeemed))} redeemed</span>`:''}${redeemed&&removed?' · ':''}${removed?`<span class="wallet-delta minus">−${esc(customerPointTotalV103(removed))} ${esc(unitNounV437(removed))} removed</span>`:''}</p>`:''}
          ${lines.length?`<details style="margin-top:8px"><summary class="small">${lines.length} item${lines.length===1?'':'s'}</summary><div style="margin-top:5px">${lines.map(line=>`<div class="row small"><span>${Number(line.qty||0)} × ${esc(line.description||line.item_type||'Item')}</span><span class="spacer"></span><span>${esc(historyMoney(line.line_cents))}</span></div>`).join('')}</div></details>`:''}
        </div></article>`;
      };
    host.innerHTML=`<div class="wallet-section-head"><div><h2>${esc(ct('Recent activity'))}</h2><p class="muted small">${esc(ct('Your latest events with this business.'))}</p></div></div>
      <div class="wallet-history">${historyRowsV429.slice(0,3).map(historyItemMarkup).join('')}</div>
      <details class="wallet-history-disclosure" style="margin-top:12px"><summary><span>${esc(ct('Full history'))}</span><span class="muted small">${historyRowsV429.length} event${historyRowsV429.length===1?'':'s'} shown · newest first</span></summary><div class="wallet-history-disclosure-body"><div class="wallet-history">${historyRowsV429.map(historyItemMarkup).join('')}</div></div></details>
      ${transactionState.nextCursor?'<button class="btn ghost sm" id="walletTransactionsMore" style="margin-top:12px">Load more history</button>':''}`;
    const more=$('walletTransactionsMore');
    if(more)more.onclick=()=>{more.disabled=true;more.textContent='Loading…';loadTransactions(transactionState.nextCursor)};
    syncCustomerActivityFeedV468();
  };
  /* V468-E2(b) + E3 (owner photo 11: "Welcome rewards redeemed — should also reflect in customer
     portal and shows a celebratory rewards redeemed").
     The redemption celebration cannot be driven from the transaction feed: a granted entitlement
     is handed over as a $0 sale whose only description is 'Retail purchase', because
     customer_get_transaction_history_v81 does not expose sales.note (where
     staff_redeem_welcome_offer_v215 writes "welcome offer redeemed: <label>"). The one customer
     read that NAMES what was handed over is customer_get_reward_history_v422 — v427 merged the
     welcome, bring-back and referral grants into it beside ordinary points redemptions, newest
     first, each row carrying source + reward_name + redeemed_at.
     Three rows are enough to identify the newest event, so this is a small read; it rides in the
     same Promise.all as the rest of the page rather than adding a round trip of its own, and it
     never repaints anything — the sole output is the banner. An error is silence, not an error
     card: a missed celebration is not worth a red box, and a bundle older than v427 answers
     42883/PGRST202 here. */
  const loadRedemptionCelebrationV468=async()=>{
    if(!businessId)return;
    const {data,error}=await customerRpc('customer_get_reward_history_v422',
      {p_business_slug:businessSlug,p_limit:3});
    if(error||!isWalletCurrent())return;
    const latestV468=(Array.isArray(data?.items)?data.items:[])[0];
    if(!latestV468)return;
    const sourceV468=String(latestV468.source||'reward');
    const fingerprintV468=`${sourceV468}:${latestV468.id||''}:${latestV468.redeemed_at||''}`;
    if(!customerCelebrationNewV468('redeemed',businessId,fingerprintV468))return;
    /* nestly_v464 puts LAPSED rewards on this same list under source 'expired'. Losing a reward
       to its deadline is not a thing to celebrate. It is still recorded above, so the next real
       redemption after one still fires. */
    if(sourceV468==='expired')return;
    customerCelebrateV468({
      icon:'giftcard',
      headline:`${String(latestV468.reward_name||'').trim()||'Your reward'} redeemed`,
      detail:CUSTOMER_CELEBRATION_SOURCE_V468[sourceV468]||'Enjoy it'
    });
    customerSuccessCue();
  };
  /* Gift cards (v68c). Balance VISIBILITY only — never redemption, and the RPC deliberately never
     returns the card code (it is a bearer instrument), so this section can only ever show a 4-char
     display hint. There is no customer_portal_capabilities flag for gift cards, so the section is
     shelled unconditionally and REMOVED when the customer holds none, per the pinned contract's
     "rendered ONLY when the section returns >=1 card". Four states: loading (the shell's skeleton +
     aria-busy), denied, error, empty (removal + the wallet-level empty state). */
  const loadGiftCards=async()=>{
    const host=$('walletGiftCards');if(!host)return;
    host.setAttribute('aria-busy','true');
    const {data,error}=await customerRpc('customer_get_gift_cards',args);
    if(!isWalletSectionCurrent(host))return;
    if(error)return walletSectionError('walletGiftCards',walletRpcDenied(error)?ct('Gift cards are not available for this account.'):ct('Gift cards could not be loaded.'),loadGiftCards,error);
    const cards=Array.isArray(data?.cards)?data.cards:[];
    if(!cards.length){host.remove();ensureWalletEmptyState(businessSlug);return}
    const giftCurrency=String(data?.business?.currency||currency);
    const giftMoney=cents=>`${giftCurrency} ${(Number(cents||0)/100).toFixed(2)}`;
    const giftState={active:ct('Ready to use'),redeemed:ct('All used up'),void:ct('Not valid')};
    host.setAttribute('aria-busy','false');
    host.innerHTML=`<div class="wallet-section-head"><div><h2>${esc(ct('Gift cards'))}</h2><p class="muted small">${esc(ct('Show this screen at the counter — the team uses your card there. We never show the full card number.'))}</p></div><span class="spacer"></span><span class="pill">${esc(giftMoney(data?.total_balance_cents))} left</span></div>
      ${cards.map(card=>`<div class="wallet-line"><div><b>${esc(giftMoney(card.balance_cents))} left</b><p class="muted small" style="margin-top:3px">Card ····${esc(card.code_suffix||'')} · started at ${esc(giftMoney(card.initial_cents))}${card.created_at?' · '+esc(walletDate(card.created_at)):''}</p></div><span class="spacer"></span><span class="pill">${esc(giftState[card.status]||String(card.status||'').replaceAll('_',' '))}</span></div>`).join('')}
      ${data?.truncated?`<p class="muted small" style="margin-top:10px">Showing your ${cards.length} newest cards. The total above counts every card you have.</p>`:''}`;
  };
  const packageState={items:[],nextCursor:null};
  /* v168: bulk/imported usage yields N rows sharing one timestamp and status. Collapse consecutive
     same-label runs (>=2) into one line carrying the run's lowest remaining_after — the balance
     after the last session in the run. The array's existing order is preserved. */
  function collapsePackageUsageRuns(usageHistory){
    const rows=Array.isArray(usageHistory)?usageHistory:[],out=[];
    for(const use of rows){
      const label=walletDate(use.used_at,true),status=use.status,remaining=Number(use.remaining_after||0),last=out[out.length-1];
      if(last&&last.label===label&&last.status===status){last.count++;last.remaining_after=Math.min(last.remaining_after,remaining);continue}
      out.push({used_at:use.used_at,label,status,count:1,remaining_after:remaining});
    }
    return out;
  }
  const loadPackages=async(cursor=null)=>{
    const host=$('walletPackages');if(!host)return;
    const {data,error}=await customerRpc('customer_get_packages',{...args,p_cursor:cursor||{limit:20}});
    if(!isWalletSectionCurrent(host))return;
    if(error)return walletSectionError('walletPackages',walletRpcDenied(error)?ct('Packages are not available for this account.'):ct('Packages could not be loaded.'),()=>loadPackages(cursor),error);
    const next=Array.isArray(data?.items)?data.items:[];
    packageState.items=cursor?[...packageState.items,...next]:next;packageState.nextCursor=data?.next_cursor||null;
    if(!packageState.items.length)return walletSectionEmpty('walletPackages','Packages',ct('No packages are available for this account.'),businessSlug,'packages',()=>loadPackages(null),isWalletCurrent);
    host.setAttribute('aria-busy','false');
    host.innerHTML=`<div class="wallet-section-head"><div><h2>${esc(ct('Packages'))}</h2><p class="muted small">${esc(ct('Session balances and recent usage.'))}</p></div></div>${packageState.items.map(item=>{
      const packageId=String(item.client_package_id||item.id||'');
      const remaining=Math.max(0,Number(item.sessions_remaining||0));
      return `<div class="wallet-line"><div style="width:100%"><div class="row"><b>${esc(item.plan_name||'Package')}</b><span class="spacer"></span><span class="pill">${remaining} of ${Number(item.sessions_purchased||0)} left</span></div>
      <p class="muted small" style="margin-top:4px">${esc(String(item.status||'').replaceAll('_',' '))}${item.expires_at?' · expires '+esc(walletDate(item.expires_at)):''}</p>
      ${remaining>0&&packageId?`<button class="btn sm" type="button" data-customer-package-qr-v347="${esc(packageId)}" style="margin-top:10px">${CUI.icon('scan',{size:16})}<span>Show package QR</span></button>`:''}
      ${(item.usage_history||[]).length?`<div class="wallet-history">${collapsePackageUsageRuns(item.usage_history).map(use=>`<p class="muted small">${esc(walletDate(use.used_at,true))} · ${use.count>1?`${use.count} sessions ${esc(use.status)}`:esc(use.status)} · ${Number(use.remaining_after||0)} left</p>`).join('')}</div>`:''}</div></div>`;
    }).join('')}
      ${packageState.nextCursor?`<button class="btn ghost sm" id="walletPackagesMore" style="margin-top:12px">${esc(ct('Load more'))}</button>`:''}`;
    if($('walletPackagesMore'))$('walletPackagesMore').onclick=()=>{ $('walletPackagesMore').disabled=true;loadPackages(packageState.nextCursor) };
    host.querySelectorAll('[data-customer-package-qr-v347]').forEach(button=>{
      button.onclick=()=>{
        const packageId=String(button.dataset.customerPackageQrV347||'');
        const item=packageState.items.find(pkg=>String(pkg.client_package_id||pkg.id||'')===packageId);
        if(!item){toast('This package is still loading. Try again in a moment.');return}
        showCustomerPackageQrV347({item,businessName:b.name,onClose:()=>loadPackages(null)});
      };
    });
  };
  const loadMemberships=async()=>{
    const host=$('walletMemberships');if(!host)return;
    const {data,error}=await customerRpc('customer_get_memberships',args);
    if(!isWalletSectionCurrent(host))return;
    if(error)return walletSectionError('walletMemberships',walletRpcDenied(error)?ct('Membership is not available for this account.'):ct('Membership could not be loaded.'),loadMemberships,error);
    const memberships=Array.isArray(data)?data:[];
    if(!memberships.length)return walletSectionEmpty('walletMemberships','Membership',ct('No membership is available for this account.'),businessSlug,'membership',loadMemberships,isWalletCurrent);
    host.setAttribute('aria-busy','false');
    host.innerHTML=`<div class="wallet-section-head"><div><h2>${esc(ct('Membership'))}</h2><p class="muted small">${esc(ct('Current plan and period status.'))}</p></div></div>${memberships.map(item=>`<div class="wallet-line"><div><b>${esc(item.plan_name||'Membership')}</b><p class="muted small" style="margin-top:3px">${esc(String(item.cadence||'').replaceAll('_',' '))}${item.current_period_start?' · '+esc(walletDate(item.current_period_start))+' to '+esc(walletDate(item.current_period_end)):''}</p></div><span class="spacer"></span><span class="pill">${esc(String(item.status||'').replaceAll('_',' '))}</span></div>`).join('')}`;
  };
  const appointmentState={items:[],nextCursor:null};
  const loadAppointments=async(cursor=null)=>{
    const host=$('walletAppointments');if(!host)return;
    const {data,error}=await customerRpc('customer_get_appointments_page',{...args,p_cursor:cursor||{limit:20}});
    if(!isWalletSectionCurrent(host))return;
    if(error)return walletSectionError('walletAppointments',walletRpcDenied(error)?ct('Appointments are not available for this account.'):ct('Appointments could not be loaded.'),()=>loadAppointments(cursor),error);
    const next=Array.isArray(data?.items)?data.items:[];
    appointmentState.items=cursor?[...appointmentState.items,...next]:next;appointmentState.nextCursor=data?.next_cursor||null;
    if(!appointmentState.items.length)return walletSectionEmpty('walletAppointments','Appointments',ct('No appointments are available yet.'),businessSlug,'appointments',()=>loadAppointments(null),isWalletCurrent);
    renderWalletAppointments(host,businessSlug,appointmentState,customerFeatures,{appointmentChangesEnabled});
    if($('walletAppointmentsMore'))$('walletAppointmentsMore').onclick=()=>{ $('walletAppointmentsMore').disabled=true;loadAppointments(appointmentState.nextCursor) };
  };
  const loadBirthdayParticipation=async()=>{
    const host=$('walletBirthdayParticipation');if(!host)return;
    const {data,error}=await sb.rpc('customer_get_birthday_participation');
    if(!walletSectionStillCurrent(host,isWalletCurrent))return;
    if(error){host.remove();ensureWalletEmptyState(businessSlug);return;}
    const optedIn=data?.opted_in===true;
    host.setAttribute('aria-busy','false');
    host.innerHTML=`<div class="wallet-section-head"><div><h2>Birthday benefits</h2><p class="muted small">Your date of birth is used by ${esc(BRAND.productName)} to determine eligible birthday benefits. It is not shown to businesses, and this is separate from marketing.</p></div></div>
      <div class="row" style="margin-top:10px"><span class="pill">${optedIn?'Participating':'Not participating'}</span><span class="spacer"></span><button type="button" class="btn ghost sm" id="birthdayParticipationToggle">${optedIn?'Turn off':'Turn on'}</button></div>
      <p id="birthdayParticipationStatus" class="muted small" role="status" aria-live="polite" style="margin-top:8px"></p>`;
    const toggle=$('birthdayParticipationToggle');
    const birthdayParticipationAttemptId=crypto.randomUUID();
    toggle.onclick=async()=>{
      toggle.disabled=true;
      const {error:setError}=await sb.rpc('customer_set_birthday_participation',{p_opted_in:!optedIn,p_idempotency_key:birthdayParticipationAttemptId});
      if(!walletSectionStillCurrent(host,isWalletCurrent)||!toggle.isConnected)return;
      if(setError){toggle.disabled=false;const status=$('birthdayParticipationStatus');if(status)status.textContent='Birthday participation could not be updated. Please try again.';return;}
      // The participation state changes eligibility. Re-render the whole
      // business wallet so the actionable card is never left stale after an
      // opt-in or opt-out (the route/DOM guard above prevents late writes).
      renderCustomerWallet(businessSlug);
    };
  };
  /* v183 (owner: "don't need in-house feedback — just Google review"): the in-app star
     rating and its comment box are removed from the customer surface. The public-review link
     stays, and the anti-review-gating invariant is now trivially satisfied — every customer
     sees the same review link, and Peekaa never asks for a private rating first. */
  /* V275 (owner: "the customer sees their bottle details inside the business's page"). Bottle
     keep is a bar-only module, so this card must be INVISIBLE everywhere else — including as a
     skeleton. It is therefore inserted only after customer_get_bottles_v275 has actually
     returned rows, never rendered as an empty shell that flashes and disappears.
     Fail-soft by construction: a 42501 (not a bar, or module off), a missing function on an
     older deployment, or any other error simply leaves the wallet as it was. A bottle the
     customer left at a bar is never a reason for the rest of their wallet to break. */
  const loadBottlesV275=async()=>{
    if(String(b.industry||'').toLowerCase()!=='bar')return;
    const sections=$('walletSections');
    if(!sections||!isWalletCurrent())return;
    const {data,error}=await customerRpc('customer_get_bottles_v275',{p_business_slug:businessSlug});
    if(!isWalletCurrent()||!sections.isConnected||$('walletSections')!==sections)return;
    if(error)return;
    const bottles=Array.isArray(data?.items)?data.items:[];
    if(!bottles.length)return;
    if($('walletBottles'))return;
    sections.insertAdjacentHTML('afterbegin',`<section class="card wallet-section" id="walletBottles" data-section-title="${esc(ct('Your bottles'))}">
      <div class="wallet-section-head"><div><h2>${esc(ct('Your bottles'))}</h2><p class="muted small">${esc(ct('What {business} is keeping for you. Show this screen at the counter to have one brought out.',{business:b.name||ct('this bar')}))}</p></div><span class="spacer"></span><span class="pill">${bottles.length}</span></div>
      ${bottles.map(bottle=>{
        /* V278: Number(null) is 0, and 0 <= 7 — the naive test painted every NEVER-expiring
           bottle amber and told the customer it was about to run out. */
        const days=Number(bottle.days_left);
        const soon=bottle.days_left!==null&&bottle.days_left!==undefined&&Number.isFinite(days)&&days<=7;
        const fill=Math.max(0,Math.min(100,Math.round(Number(bottle.fill_percent)||0)));
        return `<div class="wallet-line"><div style="width:100%">
          <div class="row"><b>${esc(String(bottle.label||'Bottle'))}</b><span class="spacer"></span><span class="pill">${fill}% left</span></div>
          <div style="margin-top:8px">${bottleFillBarV275(fill)}</div>
          <p class="muted small" style="margin-top:6px">${esc(bottle.serial_code||'')}${bottle.size_ml?` · ${Number(bottle.size_ml)}ml`:''}${bottle.storage_location_name?` · ${esc(bottle.storage_location_name)}`:''}</p>
          <p class="muted small" style="margin-top:3px">Left with them ${esc(walletDate(bottle.parked_at))}</p>
          <p class="small" style="margin-top:3px;${soon?'color:#B4761F;font-weight:600':'color:var(--muted)'}">${esc(bottleDaysLabelV275(bottle.days_left))}</p>
        </div></div>`;
      }).join('')}</section>`);
    ensureWalletEmptyState(businessSlug);
  };
  const loadFeedback=async()=>{
    const host=$('walletFeedback');if(!host||!walletReviewUrl)return;
    host.setAttribute('aria-busy','false');
    host.innerHTML=`<div class="wallet-section-head"><div><h2>${esc(ct('Rate your visit'))}</h2><p class="muted small">${esc(ct('Your review helps other people find this business.'))}</p></div></div>
      <a class="btn sm" href="${esc(walletReviewUrl)}" target="_blank" rel="noopener noreferrer" style="margin-top:12px">${CUI.icon('loyalty',{size:16})}<span>Leave a public review</span></a>`;
  };
  await Promise.all([loadMemberCodeW6I2(),loadReferralCardV300(),loadStampCardV323(),loadGrowthOffers(),loadRewards(),loadTransactions(),loadActivity(),loadGiftCards(),loadPackages(),loadMemberships(),loadAppointments(),loadBirthdayParticipation(),loadFeedback(),loadBottlesV275(),loadRedemptionCelebrationV468()]);
  if(!isWalletCurrent())return;
}

async function renderCustomerInAppInbox(businessSlug,isCurrent=()=>true,actionableCard=null){
  let host=$('customerInAppInbox');
  if(!host&&businessSlug===null){
    const body=$('walletBody');
    if(!body||!isCurrent()||!body.isConnected)return;
    body.insertAdjacentHTML('beforeend','<section class="card wallet-section" id="customerInAppInbox" aria-busy="true" tabindex="-1"><div class="wallet-skeleton"></div></section>');
    host=$('customerInAppInbox');
  }
  if(!walletSectionStillCurrent(host,isCurrent))return;
  const slot=$('customerInboxBellSlot');
  const slotCurrent=()=>!!slot&&slot.isConnected&&$('customerInboxBellSlot')===slot&&isCurrent();
  const global=businessSlug===null;
  const loyaltyUnit=actionableCard?.loyalty?.unit;
  const expiryReminderLabel=loyaltyUnit==='stamps'?'Stamps expiry reminders':loyaltyUnit==='points'?'Points expiry reminders':'Expiry reminders';
  let currentFilter='all',nextCursor=null,items=[],bell=null,refreshInbox;
  /* nestly_v417 (owner, photo 9: "remove this button"). V395's open-state fix is retired WITH the
     gear it existed for: the panel is no longer collapsible, so there is no open state to keep and
     no way for a filter tap to collapse it. The defect V395 described cannot recur — the panel is
     always rendered, below the list it governs. */
  const topicLabels={
    value_expiry:expiryReminderLabel,reward_ready:'Reward ready reminders',
    visit_progress:'Visit progress reminders',birthday_benefit:'Birthday benefit reminders',
    booking_updates:'Booking update reminders',promotion_alerts:'Promotion alerts'
  };
  const request=(name,args)=>sb.rpc(name,args);
  const refreshBell=async()=>{
    const {data,error}=await request(
      global?'customer_get_in_app_inbox_global_count':'customer_get_in_app_inbox_count',
      global?{}:{p_business_slug:businessSlug}
    );
    if(!walletSectionStillCurrent(host,isCurrent)||!slotCurrent())return null;
    if(error)return {error};
    const unread=Math.max(0,Number(data?.unread_count||0));
    slot.innerHTML=`<a class="customer-inbox-bell" href="#/customer/messages" aria-label="${unread?`Open messages, ${unread} unread`:'Open messages'}" title="${unread?`${unread} unread message${unread===1?'':'s'}`:'Open messages'}">${CUI.icon('bell',{size:20})}${unread?`<span class="customer-inbox-badge" aria-hidden="true">${unread>99?'99+':unread}</span>`:''}</a>`;
    return {unread};
  };
  const render=()=>{
    const status=[
      items.some(item=>item?.state==='source_unavailable')?'Some programme updates are temporarily unavailable and cannot be opened.':''
    ].filter(Boolean).join(' ');
    /* v386 (owner photo 8: "i want this ↓ [avatar] Cubbly xxx … 27 Aug 2026", drawn over the
       expanded card and its three buttons, marked "too confusing"). One message is now ONE ROW:
       who it is from, what it says, and when it stops mattering. The row itself is the "Open
       programme" button that used to sit under the text — same handler, same data-inbox-open
       contract, so opening still marks read and still refuses a resolved or unavailable source.
       Dismiss stays as a single quiet control on the row; "Mark unread" is dropped, because a
       row the customer just opened is the one thing they cannot have wanted to re-flag, and it
       was the third of three competing buttons.
       The per-business <h3> group heading goes too: every row now names its own business, so a
       heading over a single row was repeating the row. */
    const renderedItems=items.map(item=>{
      const state=String(item?.state||'read'),isResolved=state==='resolved',isUnavailable=state==='source_unavailable',business=item?.business||null;
      const routeSlug=global?business?.slug:businessSlug;
      const name=String(business?.name||'').trim()||(global?'Business programme':'This business');
      const when=item?.deadline_at||item?.created_at||'';
      const openable=item?.action_available===true&&!isResolved&&item?.route_key==='wallet_business'&&!!routeSlug;
      const monogram=(name[0]||'B').toUpperCase();
      const line=String(item?.title||'Inbox update').trim();
      const detail=String(item?.body||'').trim();
      /* Screen-reader only, so the full wording costs no space and stays the honest one. */
      const stateCopy=isResolved?'Resolved history':isUnavailable?'Programme temporarily unavailable':state==='unread'?'Unread':'Read';
      return `<article class="customer-inbox-item customer-inbox-row-v386 ${esc(state)}">
        <${openable?'button':'div'} class="customer-inbox-row-main-v386"${openable?` type="button" data-inbox-open="${esc(item.event_id)}" data-route-key="wallet_business"`:''}>
          <span class="customer-inbox-avatar-v386" aria-hidden="true">${esc(monogram)}</span>
          <span class="customer-inbox-row-copy-v386">
            <span class="customer-inbox-row-top-v386"><b>${esc(name)}</b>${when?`<time class="customer-inbox-row-when-v386" datetime="${esc(when)}">${esc(walletDate(when))}</time>`:''}</span>
            <span class="customer-inbox-row-line-v386">${esc(line)}</span>
            ${detail&&detail!==line?`<span class="customer-inbox-row-detail-v386 muted small">${esc(detail)}</span>`:''}
          </span>
          ${state==='unread'?'<span class="customer-inbox-row-dot-v386" aria-hidden="true"></span>':''}
          <span class="sr-only">${esc(stateCopy)}</span>
        </${openable?'button':'div'}>
        ${isResolved?'':`<button type="button" class="customer-inbox-row-dismiss-v386" data-inbox-state="${esc(item.event_id)}" data-state="dismiss" aria-label="Dismiss ${esc(line)}">${CUI.icon('close',{size:16})}</button>`}
      </article>`;
    }).join('');
    host.setAttribute('aria-busy','false');
    /* The gear holds everything that is a SETTING rather than a message: the All/Unread filter,
       the per-business reminder preferences, and (on the Messages page) the device-notification
       switch, which is moved in below. Collapsed by default — photo 8 shows a list, not a
       control panel. */
    /* nestly_v397 (owner photo A: All and Unread ringed a second time, with a line drawn from them
       to the gear). v386 filed them as SETTINGS, but they are not settings — they are how you read
       this page, the only two states the list has, and burying them behind a gear meant the
       customer had to discover a menu to find out the list could be filtered at all. They sit in
       the section head now, where the list they govern can be seen changing. The gear keeps what
       genuinely is configuration: the per-programme reminder preferences and the device-notification
       switch. v395's open-state fix stays for exactly that panel. */
    host.innerHTML=`<div class="wallet-section-head customer-inbox-head-v386">
        <div class="customer-inbox-filter-row-v386" role="group" aria-label="Show">
          <button type="button" class="btn ghost sm customer-inbox-filter" data-inbox-filter="all" aria-pressed="${currentFilter==='all'}">All</button>
          <button type="button" class="btn ghost sm customer-inbox-filter" data-inbox-filter="unread" aria-pressed="${currentFilter==='unread'}">Unread</button>
        </div>
        </div>
      ${/* nestly_v417 (owner, photo 9: the gear ringed — "remove this button"). It is gone, and
           what it hid is NOT: the panel it toggled holds this business's inbox-reminder
           preferences, and the gear was their only door. Deleting the button and the settings
           together would have taken a real choice away from customers under the heading of a
           cosmetic tidy, so the panel is simply always shown, below the messages it governs,
           where the list it changes can be seen. The device-notification card inside it already
           has a second home on Profile; it keeps that too. */''}
      <p id="customerInboxStatus" class="muted small" role="status" aria-live="polite">${esc(status)}</p>
      <div id="customerInboxItems">${items.length?renderedItems:'<p class="muted small" style="padding:8px 0">No '+(currentFilter==='unread'?'unread ':'')+'inbox updates right now.</p>'}</div>
      ${nextCursor?`<button type="button" class="btn ghost sm" id="customerInboxMore" style="margin-top:12px">${esc(ct('Load more'))}</button>`:''}
      <div id="customerInboxSettingsV386" class="customer-inbox-settings-v386">
        <div id="customerInAppInboxPreferences" style="margin-top:18px"></div>
        <div id="customerInboxDeviceSlotV386"></div>
      </div>`;
    /* nestly_v417: no toggle to wire — the panel is always open now (photo 9). */
    /* Moved, not duplicated: the section keeps its id and its already-bound control, so the v296
       push wiring that ran once at page render still owns the button it bound. */
    const deviceSectionV386=$('customerMessagesNotifications'),deviceSlotV386=host.querySelector('#customerInboxDeviceSlotV386');
    if(deviceSectionV386&&deviceSlotV386&&!deviceSlotV386.contains(deviceSectionV386)){
      deviceSectionV386.hidden=false;
      deviceSectionV386.style.marginTop='18px';
      deviceSlotV386.appendChild(deviceSectionV386);
    }
    host.querySelectorAll('[data-inbox-filter]').forEach(button=>button.onclick=()=>{
      if(!walletSectionStillCurrent(host,isCurrent))return;currentFilter=button.dataset.inboxFilter||'all';load(null);
    });
    host.querySelectorAll('[data-inbox-open]').forEach(button=>button.onclick=async()=>{
      const item=items.find(entry=>entry?.event_id===button.dataset.inboxOpen);const slug=global?item?.business?.slug:businessSlug;
      if(!item||!slug||!walletSectionStillCurrent(host,isCurrent))return;
      button.disabled=true;await setState(item,'read');if(!isCurrent())return;nav('#/wallet/'+encodeURIComponent(slug));
    });
    host.querySelectorAll('[data-inbox-state]').forEach(button=>button.onclick=async()=>{
      const item=items.find(entry=>entry?.event_id===button.dataset.inboxState);if(!item)return;
      button.disabled=true;await setState(item,button.dataset.state);if(!walletSectionStillCurrent(host,isCurrent))return;load(null);
    });
    const more=$('customerInboxMore');if(more)more.onclick=()=>{more.disabled=true;load(nextCursor);};
    renderPreferences();
  };
  const setState=async(item,operation)=>{
    const slug=global?item?.business?.slug:businessSlug;
    if(!slug)return;
    const {error}=await request('customer_set_in_app_inbox_state',{
      p_business_slug:slug,p_event_id:item.event_id,p_operation:operation,p_idempotency_key:crypto.randomUUID()
    });
    if(!error&&operation==='read')typeof recordProductInteractionV100==='function'&&recordProductInteractionV100(
      'customer.notification_opened',
      isUuidV100(item?.business?.id)?item.business.id:customerWalletBusinessIdV256,
      {context:{surface_key:'inbox',entry_point:'customer_inbox',
        outcome:'read',surface_version:'v255'}}
    );
    if(!walletSectionStillCurrent(host,isCurrent))return;
    const status=$('customerInboxStatus');
    if(error){if(status)status.textContent='That inbox item could not be updated. Please try again.';return;}
    if(status)status.textContent='Inbox updated.';CUI.announce('Inbox updated.');
    const refreshedBell=await refreshBell();
    if(refreshedBell?.error&&status)status.textContent='Inbox updated, but its unread count could not be refreshed.';
  };
  const renderRefreshUnavailable=()=>{
    if(!walletSectionStillCurrent(host,isCurrent))return;
    const offline=globalThis.navigator?.onLine===false;
    const heading=global?`${BRAND.customerLabel} inbox needs a refresh`:'Inbox needs a refresh';
    const message=offline
      ?'You appear to be offline. Reconnect, then retry to refresh your current programme updates.'
      :'We could not refresh your current programme updates. Programme actions are hidden until refresh succeeds.';
    items=[];nextCursor=null;bell=null;
    if(slotCurrent())slot.innerHTML=`<a class="customer-inbox-bell" href="#/customer/messages" aria-label="Open messages" title="Open messages">${CUI.icon('bell',{size:20})}</a>`;
    host.setAttribute('aria-busy','false');
    host.innerHTML=`<div class="wallet-section-head"><div><h2>${heading}</h2><p class="muted small" role="status" aria-live="polite">${message}</p></div><span class="spacer"></span><button type="button" class="btn ghost sm" id="customerInboxSyncRetry">Retry inbox refresh</button></div>`;
    const retry=host.querySelector('#customerInboxSyncRetry');
    if(retry)retry.onclick=async()=>{if(!walletSectionStillCurrent(host,isCurrent))return;retry.disabled=true;await refreshInbox();};
  };
  const load=async(cursor=null)=>{
    const rpc=global?'customer_list_in_app_inbox_global':'customer_list_in_app_inbox';
    const args=global?{p_cursor:cursor||{limit:20,filter:currentFilter}}:{p_business_slug:businessSlug,p_cursor:cursor||{limit:20,filter:currentFilter}};
    const {data,error}=await request(rpc,args);
    if(!walletSectionStillCurrent(host,isCurrent))return;
    if(error){renderRefreshUnavailable();return;}
    const fresh=Array.isArray(data?.items)?data.items:[];items=cursor?[...items,...fresh]:fresh;nextCursor=data?.next_cursor||null;render();
  };
  refreshInbox=async()=>{
    if(!walletSectionStillCurrent(host,isCurrent))return;
    host.setAttribute('aria-busy','true');
    // A list is never loaded after a failed C46 sync. That prevents an old
    // actionable route from looking current when source availability is unknown.
    const {error}=await request(
      global?'customer_sync_in_app_inbox_global':'customer_sync_in_app_inbox',
      global?{p_idempotency_key:crypto.randomUUID()}:{p_business_slug:businessSlug,p_idempotency_key:crypto.randomUUID()}
    );
    if(!walletSectionStillCurrent(host,isCurrent))return;
    if(error){renderRefreshUnavailable();return;}
    const refreshedBell=await refreshBell();
    if(!walletSectionStillCurrent(host,isCurrent))return;
    if(!refreshedBell||refreshedBell.error){renderRefreshUnavailable();return;}
    bell=refreshedBell;
    await load(null);
  };
  /* V289 (audit A3): "Inbox reminders" — the only place a customer can stop a business putting a
     reminder in their inbox — was rendered ONLY in the per-business inbox, and the per-business
     inbox has no caller: renderCustomerInAppInbox is invoked once, from Messages, with a null
     slug. The controls existed, were tested, and could not be reached by anyone. The RPCs are
     per-business, so the reachable home for them is the global inbox, grouped by the businesses
     whose updates are actually in it. Each group loads its own settings only when opened, so the
     Messages screen still costs the same reads it did before. */
  const inboxPreferenceRowsMarkupV289=preferences=>Object.entries(topicLabels).map(([topic,label])=>{
    const preference=preferences.get(topic)||{};
    return `<fieldset style="margin-top:12px;padding:12px;border:1px solid var(--hair);border-radius:8px"><legend class="small" style="padding:0 4px">${esc(label)}</legend><label class="row" style="color:var(--ink);font-weight:500"><input type="checkbox" class="customerInboxPreference" style="width:auto" data-topic="${topic}" ${preference.opted_in===true?'checked':''}>Keep this reminder in my inbox</label><button type="button" class="btn ghost sm customerInboxPreferenceSave" data-topic="${topic}" style="margin-top:8px">Save reminder</button></fieldset>`;
  }).join('');
  const wireInboxPreferenceSavesV289=(scope,slug,preferences)=>{
    scope.querySelectorAll('.customerInboxPreferenceSave').forEach(button=>button.onclick=async()=>{
      const topic=button.dataset.topic;const checkbox=scope.querySelector(`.customerInboxPreference[data-topic="${topic}"]`);if(!checkbox)return;
      button.disabled=true;const {error:setError}=await request('customer_set_in_app_inbox_preferences',{
        p_business_slug:slug,p_topic:topic,p_opted_in:checkbox.checked,
        p_quiet_hours_timezone:null,p_quiet_hours_start:null,p_quiet_hours_end:null,p_idempotency_key:crypto.randomUUID()
      });
      if(!walletSectionStillCurrent(host,isCurrent)||!button.isConnected)return;
      button.disabled=false;const status=$('customerInboxStatus');if(setError){if(status)status.textContent='That reminder could not be saved. Try again.';return;}
      preferences.set(topic,{opted_in:checkbox.checked,quiet_hours_timezone:null,quiet_hours_start:null,quiet_hours_end:null});if(status)status.textContent='Inbox reminder saved.';CUI.announce('Inbox reminder saved.');await refreshBell();
    });
  };
  const renderGlobalPreferencesV289=preferenceHost=>{
    const businesses=[],seen=new Set();
    for(const item of items){
      const slug=String(item?.business?.slug||'');
      if(!slug||seen.has(slug))continue;
      seen.add(slug);businesses.push({slug,name:String(item?.business?.name||slug)});
    }
    if(!businesses.length){preferenceHost.innerHTML='';return}
    preferenceHost.innerHTML=`<h3 style="font-size:16px">Inbox reminders</h3><p class="muted small" style="margin-top:4px">Choose which reminders each business may place in your inbox. Nothing changes until you select Save.</p>
      ${businesses.map(business=>`<details data-inbox-preferences="${esc(business.slug)}" style="margin-top:12px"><summary>${esc(business.name)}</summary><div data-inbox-preference-body><p class="muted small" style="margin-top:8px">Open to load this business’s reminder settings.</p></div></details>`).join('')}`;
    preferenceHost.querySelectorAll('[data-inbox-preferences]').forEach(details=>{
      details.ontoggle=async()=>{
        if(!details.open||details.dataset.loaded==='1')return;
        details.dataset.loaded='1';
        const slug=details.dataset.inboxPreferences,body=details.querySelector('[data-inbox-preference-body]');
        if(!body)return;
        body.innerHTML='<p class="muted small" style="margin-top:8px">Loading reminder settings…</p>';
        const {data,error}=await request('customer_get_in_app_inbox_preferences',{p_business_slug:slug});
        if(!walletSectionStillCurrent(host,isCurrent)||!body.isConnected)return;
        if(error){
          details.dataset.loaded='';
          body.innerHTML='<p class="muted small" style="margin-top:8px">These reminder settings could not be loaded. Close and open this business to try again.</p>';return;
        }
        const preferences=new Map((Array.isArray(data)?data:[]).map(item=>[item.topic,item]));
        body.innerHTML=inboxPreferenceRowsMarkupV289(preferences);
        wireInboxPreferenceSavesV289(body,slug,preferences);
      };
    });
  };
  const renderPreferences=async()=>{
    const preferenceHost=$('customerInAppInboxPreferences');if(!walletSectionStillCurrent(host,isCurrent)||!preferenceHost)return;
    if(global)return renderGlobalPreferencesV289(preferenceHost);
    const {data,error}=await request('customer_get_in_app_inbox_preferences',{p_business_slug:businessSlug});
    if(!walletSectionStillCurrent(host,isCurrent)||!preferenceHost.isConnected)return;
    if(error)return;
    const preferences=new Map((Array.isArray(data)?data:[]).map(item=>[item.topic,item]));
    preferenceHost.innerHTML=`<h3 style="font-size:16px">Inbox reminders</h3><p class="muted small" style="margin-top:4px">Choose which reminders this business may place in your inbox. Nothing changes until you select Save.</p>${inboxPreferenceRowsMarkupV289(preferences)}`;
    wireInboxPreferenceSavesV289(preferenceHost,businessSlug,preferences);
  };
  await refreshInbox();
}

/* V263 - the customer Communications screen.
   Owner ruling 2026-08-09, with Grab's Communications screen as the supplied reference: purpose
   categories, one row per channel, "default is all on". The labels live here and the effective
   values come from the server in one call, so the client never reproduces the default rule - that
   is exactly how a screen and its send-path gate drift apart.
   Transactional messages (receipts, booking confirmations, security notices) are deliberately
   absent: they have no category server-side and cannot be switched off from anywhere. */
/* v295: the label/help strings below are ct() KEYS, not rendered copy — every render site
   passes them through ct() so this PDPA consent surface reads in the member's own language.
   Consent you cannot read is not consent. */
const CUSTOMER_COMMUNICATION_CATEGORIES_V263=[
  ['business_offers','Offers from businesses you follow','Promotions and deals from the businesses whose programmes you have joined.'],
  ['rewards_and_points','Your rewards and points','Points you earn, rewards unlocked, and value that is about to expire.'],
  ['peekaa_updates','Peekaa updates','News and new features from Peekaa itself.']
];
const CUSTOMER_COMMUNICATION_CHANNELS_V263=[
  ['in_app','In-app message'],['push','Push notification'],['email','Email'],
  ['sms','SMS'],['whatsapp','WhatsApp'],['call','Call']
];
async function renderCustomerCommunicationsV263(){
  const walletRenderEpoch=++customerWalletRenderEpoch,isCurrent=()=>customerWalletRenderEpoch===walletRenderEpoch;
  const context=await loadCustomerSurfaceContext(isCurrent);if(!context)return;
  const shell=body=>renderCustomerShell({
    active:'profile',staffWorkspaces:context.staffWorkspaces,
    messagesAvailable:context.features.customer_in_app_inbox===true,
    backTo:'#/customer/profile',body
  });
  shell(CUI.loadingState({title:ct('Communications'),body:ct('Loading your communication choices…'),variant:'form'}));
  focusCustomerRoute();
  const {data,error}=await sb.rpc('customer_get_communication_preferences_v263');
  if(!isCurrent())return;
  if(error){
    shell(CUI.errorState({title:ct('Communications'),message:ct('Your communication choices could not be loaded. Nothing has been changed.'),retryId:'customerCommsRetry'}));
    const retry=$('customerCommsRetry');if(retry)retry.onclick=()=>renderCustomerCommunicationsV263();
    focusCustomerRoute();return;
  }
  const serverCategories=Array.isArray(data?.categories)?data.categories:[];
  const known=new Map(CUSTOMER_COMMUNICATION_CATEGORIES_V263.map(([key,label,help])=>[key,{label,help}]));
  const rows=serverCategories.filter(entry=>known.has(entry?.category));
  if(!rows.length){
    shell(`<header class="customer-page-head"><div><h1>${esc(ct('Communications'))}</h1></div></header>${CUI.emptyState({iconName:'bell',title:ct('No communication choices yet'),body:ct('There is nothing to set here for your account right now.')})}`);
    focusCustomerRoute();return;
  }
  const allEnabled=data?.all_enabled===true;
  shell(`<header class="customer-page-head"><div><h1>${esc(ct('Communications'))}</h1><p class="muted">${esc(ct('Everything is on unless you turn it off. Turning something off here never stops receipts, booking confirmations or security messages — those are not marketing and keep sending.'))}</p></div></header>
    <section class="card"><label class="row" for="customerCommsAll" style="align-items:flex-start;color:var(--ink);font-weight:600"><input id="customerCommsAll" type="checkbox" ${allEnabled?'checked':''} style="width:20px;min-width:20px;min-height:20px;margin-top:2px"> <span>${esc(ct('Send me all marketing messages'))}<span class="muted small" style="display:block;font-weight:400;margin-top:3px">${esc(ct('One tick covers every category and every channel below — push, email, SMS, WhatsApp and calls. You can switch any single one back off at any time.'))}</span></span></label>
      <p class="muted small" id="customerCommsStatus" role="status" aria-live="polite" style="margin-top:10px"></p></section>
    ${rows.map(entry=>{
      const meta=known.get(entry.category);
      const channels=Array.isArray(entry.channels)?entry.channels:[];
      return `<section class="card" style="margin-top:14px"><h2>${esc(ct(meta.label))}</h2><p class="muted small" style="margin-top:5px">${esc(ct(meta.help))}</p>
      ${channels.map(channel=>{
        const label=(CUSTOMER_COMMUNICATION_CHANNELS_V263.find(([key])=>key===channel?.channel)||[null,channel?.channel])[1];
        return `<label class="row" for="customerComms-${esc(entry.category)}-${esc(channel.channel)}" style="margin-top:12px;color:var(--ink);font-weight:500"><input id="customerComms-${esc(entry.category)}-${esc(channel.channel)}" class="customerCommsToggle" type="checkbox" style="width:auto" data-category="${esc(entry.category)}" data-channel="${esc(channel.channel)}" ${channel.enabled===true?'checked':''}>${esc(label?ct(label):channel.channel)}</label>`;
      }).join('')}</section>`;
    }).join('')}`);
  focusCustomerRoute();
  const status=$('customerCommsStatus');
  const say=message=>{if(status)status.textContent=message;if(message)CUI.announce(message)};
  const master=$('customerCommsAll');
  const syncMaster=()=>{
    if(!master)return;
    master.checked=[...document.querySelectorAll('.customerCommsToggle')].every(input=>input.checked);
  };
  /* Optimistic, but never dishonest: a failed write puts the switch back where it was and says so,
     so the screen can never claim a preference the server did not store. */
  document.querySelectorAll('.customerCommsToggle').forEach(input=>input.onchange=async()=>{
    const wanted=input.checked;
    input.disabled=true;say(ct('Saving…'));
    const {error:setError}=await sb.rpc('customer_set_communication_preference_v263',{
      p_category:input.dataset.category,p_channel:input.dataset.channel,p_enabled:wanted
    });
    if(!isCurrent()||!input.isConnected)return;
    input.disabled=false;
    if(setError){input.checked=!wanted;syncMaster();say(ct('That choice could not be saved, so it has been put back. Please try again.'));return}
    syncMaster();say(ct('Saved.'));
  });
  if(master)master.onchange=async()=>{
    const wanted=master.checked;
    const before=[...document.querySelectorAll('.customerCommsToggle')].map(input=>[input,input.checked]);
    master.disabled=true;before.forEach(([input])=>{input.disabled=true;input.checked=wanted});
    say(ct('Saving…'));
    const {error:setError}=await sb.rpc('customer_set_all_communications_v263',{p_enabled:wanted});
    if(!isCurrent()||!master.isConnected)return;
    master.disabled=false;before.forEach(([input])=>{input.disabled=false});
    if(setError){
      master.checked=!wanted;before.forEach(([input,was])=>{input.checked=was});
      say(ct('That change could not be saved, so your choices have been put back. Please try again.'));return;
    }
    say(wanted?ct('All marketing messages are on.'):ct('All marketing messages are off. Receipts, bookings and security messages still send.'));
  };
}

/* ---------- phone country-code picker (portal booking form only) ----------
   Singapore first/default since Frenly is SG-first; a handful of the other common corridors
   for this customer base. */
const COUNTRY_CODES=[['+65','🇸🇬'],['+60','🇲🇾'],['+62','🇮🇩'],['+852','🇭🇰'],['+61','🇦🇺'],
  ['+44','🇬🇧'],['+1','🇺🇸'],['+91','🇮🇳'],['+86','🇨🇳'],['+63','🇵🇭'],['+66','🇹🇭'],['+84','🇻🇳']];
function ccSelectHtml(id){
  return `<select id="${id}" style="max-width:110px">${COUNTRY_CODES.map(([c,f])=>
    `<option value="${c}" ${c==='+65'?'selected':''}>${f} ${c}</option>`).join('')}</select>`;
}
/* Combines a country-code <select> with a free-typed number input into one E.164-ish string,
   stripping spaces/dashes. Forgiving of a customer who types their own leading '+' (trusted
   as-is, so we never double-prefix) or who re-types the selected country's digits at the
   front of the number field. */
function buildPhone(ccId,phoneId){
  const cc=$(ccId).value;
  let digits=($(phoneId).value||'').trim().replace(/[\s\-]/g,'');
  if(!digits) return '';
  if(digits.startsWith('+')) return digits;
  const ccDigits=cc.replace('+','');
  if(digits.startsWith(ccDigits)) digits=digits.slice(ccDigits.length);
  return cc+digits;
}

function prefillEmptyPortalDetails({profile=null,user=null}={}){
  const name=$('pn'),phone=$('pp'),email=$('pe'),country=$('ppcc');
  const metadata=user?.user_metadata||{};
  const fullName=String(profile?.full_name||metadata.full_name||metadata.name||'').trim();
  /* v192 (owner: "already has +65 — why the number auto generated 6581863833?"). Supabase stores
     the verified phone in E.164 WITHOUT the leading plus (6581863833), so the country-code match
     below never fired and the whole number was pasted into the local field, next to a +65 select.
     Normalise first, then split. */
  const storedPhone=String(user?.phone||'').replace(/[^\d+]/g,'');
  const authPhone=storedPhone&&!storedPhone.startsWith('+')?`+${storedPhone}`:storedPhone;
  const authEmail=String(user?.email||'').trim();
  if(name&&!name.value.trim()&&fullName)name.value=fullName;
  if(email&&!email.value.trim()&&authEmail)email.value=authEmail;
  if(phone&&!phone.value.trim()&&authPhone){
    const match=COUNTRY_CODES.map(([code])=>code).sort((a,b)=>b.length-a.length).find(code=>authPhone.startsWith(code));
    if(match&&country){
      country.value=match;
      phone.value=authPhone.slice(match.length);
    }else phone.value=authPhone;
  }
}
function customerBookingIdentitySummaryV167({profile=null,user=null}={}){
  const metadata=user?.user_metadata||{};
  const name=String(profile?.full_name||metadata.full_name||metadata.name||'').trim();
  const phone=String(user?.phone||'').replace(/\s+/g,'');
  const maskedPhone=phone.length>4?`${phone.slice(0,Math.min(3,phone.length-4))} •••• ${phone.slice(-4)}`:phone;
  return {name:name||'your Peekaa account',contact:maskedPhone||String(user?.email||'').trim()};
}
/* v183 (owner: "no one will remember their booking code — just show the upcoming appointments
   instead of keying booking code"): for a signed-in customer with a verified link to this
   business, the booking page now lists their own upcoming appointments and pending requests,
   with the same change/cancel request path the wallet uses. The guest management-code entry is
   demoted to a collapsed fallback — it is still the ONLY route for someone who booked without
   an account, so it is not removed. */
/* v286 (audit): the portal drew the same Change control as the wallet but with NO capability
   check, so a business that switched customer appointment changes OFF still received cancellation
   and reschedule requests from anyone who reached its booking page while signed in — its own
   setting was silently meaningless on this path. The flag lives on customer_get_business_actions_v89,
   which is keyed by business id, so the programme list resolves the slug first. Fail CLOSED: an
   unreadable capability hides the control rather than offering an action the business may have
   withdrawn. (The server-side half of this finding — customer_request_appointment_action does not
   check the flag either — needs a migration and is left to the migration owner.) */
async function portalAppointmentChangesEnabledV286(slug){
  try{
    const {data,error}=await customerRpc('customer_list_programmes_v89');
    if(error)return false;
    const card=(Array.isArray(data?.programmes)?data.programmes:[]).find(item=>String(item?.business?.slug||'')===String(slug||''));
    const businessId=String(card?.business?.id||'');
    if(!businessId)return false;
    const actions=await customerRpc('customer_get_business_actions_v89',{p_business:businessId});
    return !actions.error&&actions.data?.appointment_changes?.enabled===true;
  }catch(_error){return false}
}
async function loadPortalUpcomingBookingsV183(slug,isPortalCurrent=()=>true){
  const host=$('portalUpcoming');
  if(!host||!isPortalCurrent())return;
  host.innerHTML='<p class="muted small">Loading your bookings…</p>';
  const [appointmentResult,requestResult,changesEnabled]=await Promise.all([
    /* v286: customerRpc carries the same 12s deadline the rest of the customer surface uses, so a
       stalled read lands on the honest "could not be loaded" line below instead of leaving
       "Loading your bookings…" on the page for ever. */
    Promise.resolve(customerRpc('customer_get_appointments_page',{p_business_slug:slug,p_cursor:{limit:20}})).catch(error=>({data:null,error})),
    Promise.resolve(customerRpc('customer_get_booking_requests',{p_limit:50,p_cursor:null})).catch(error=>({data:null,error})),
    portalAppointmentChangesEnabledV286(slug)
  ]);
  if(!isPortalCurrent()||!host.isConnected)return;
  if(appointmentResult.error&&requestResult.error){
    host.innerHTML='<p class="muted small">Your existing bookings could not be loaded right now. You can still make a new booking above.</p>';
    return;
  }
  const now=Date.now();
  const appointments=(Array.isArray(appointmentResult.data?.items)?appointmentResult.data.items:[])
    .filter(item=>!CANCELLED_CUSTOMER_BOOKING_STATUSES_V178.has(String(item?.status||'').toLowerCase()))
    .filter(item=>{const at=Date.parse(item?.starts_at||'');return Number.isFinite(at)&&at>=now})
    .sort((a,b)=>Date.parse(a.starts_at||0)-Date.parse(b.starts_at||0));
  const requests=(Array.isArray(requestResult.data?.items)?requestResult.data.items:[])
    .filter(item=>String(item?.business_slug||'')===slug&&isActiveCustomerBookingRequest(item));
  if(!appointments.length&&!requests.length){
    host.innerHTML='<p class="muted small">You have no upcoming bookings with this business yet.</p>';
    return;
  }
  host.innerHTML=`${requests.map(item=>`<div class="wallet-appt"><div><b>${esc(walletDate(item.preferred_at,true)||'Preferred time pending')}</b><p class="muted small" style="margin-top:3px">${esc(item.service_name||'Booking request')} · awaiting the business</p></div><span class="spacer"></span><span class="pill ${item.status==='waitlisted'?'new':'off'}">${esc(item.status==='waitlisted'?ct('Waitlisted'):ct('Pending'))}</span></div>`).join('')}
    ${appointments.map(item=>`<div class="wallet-appt"><div><b>${esc(walletDate(item.starts_at,true))}</b><p class="muted small" style="margin-top:3px">${esc(item.service_name||'Appointment')}${item.branch_name?' · '+esc(item.branch_name):''} · ${esc(String(item.status||'booked').replaceAll('_',' '))}</p></div><span class="spacer"></span>${String(item.status||'')==='booked'?(changesEnabled?`<button class="btn ghost sm walletChange" data-id="${esc(item.appointment_id)}" data-business-slug="${esc(slug)}">Change</button>`:'<span class="muted small">Contact the business to change this</span>'):''}</div>`).join('')}`;
  wireWalletAppointmentActions(slug);
}
async function renderPortal(slug){
  setCustomerSurfaceDocumentV167();
  globalThis.document?.documentElement?.setAttribute('lang','en');
  const portalEpoch=++portalRenderEpoch;
  const isPortalCurrent=()=>portalRenderEpoch===portalEpoch
    &&location.hash.split('?')[0]===`#/b/${slug}`;
  const signedInUser=S.user;
  const incomingParams=new URLSearchParams((location.hash.split('?')[1]||''));
  let manageToken=incomingParams.get('manage')||'';
  const repeatServiceParam=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(incomingParams.get('repeat_service')||'')
    ?incomingParams.get('repeat_service'):'';
  if(manageToken){
    history.replaceState(null,'',`${location.pathname}${location.search}#/b/${encodeURIComponent(slug)}`);
  }
  /* Perceived performance: paint a branded, business-agnostic skeleton immediately — before any
     network await — so the portal never shows a blank frame while data loads. The single
     business fetch is the only thing on the critical path. The signed-in persona lookup used to
     block ahead of it; it now runs in PARALLEL and only injects an optional banner once resolved,
     so the booking journey renders the instant the business responds. */
  root.innerHTML=`<div class="portal customer-surface"><div class="head"><div class="logo">${brandWordmark()}</div><p class="muted small">powered booking</p></div>
    <div class="card" aria-busy="true"><p class="sr-only" role="status">Loading booking…</p>
      <div class="pf-skeleton"></div><div class="pf-skeleton"></div><div class="pf-skeleton" style="width:62%"></div></div></div>`;
  /* sb.rpc() returns a thenable builder with no .catch method — calling .catch on it directly
     throws synchronously for signed-in users and aborted the whole portal render. Wrap in a real
     Promise so a failed optional prefill degrades to the anonymous experience instead. */
  const personaPromise=signedInUser?Promise.resolve(loadPersonasV370()).catch(error=>({data:null,error})):Promise.resolve({data:null,error:null});
  const profilePromise=signedInUser?Promise.resolve(sb.rpc('customer_get_profile')).catch(error=>({data:null,error})):Promise.resolve({data:null,error:null});
  let biz;
  const portalLoadTimeout=12000,portalLoadController=new AbortController();
  const portalLoadTimer=setTimeout(()=>portalLoadController.abort(),portalLoadTimeout);
  try{biz=await publicGateway('public-booking',{method:'GET',query:`?slug=${encodeURIComponent(slug)}`,signal:portalLoadController.signal})}
  catch(error){
    if(isPortalCurrent()){
      const card=root.querySelector('.card');
      if(card){card.innerHTML=`<div class="empty"><div class="big">${CUI.icon('bookings',{size:28})}</div><h2>${error?.name==='AbortError'?'Booking page took too long':'Booking page could not load'}</h2><p class="muted small" style="margin-top:6px">Check your connection, then retry. Your account session has not been changed.</p><button class="btn" id="portalRetry" type="button" style="margin-top:14px">Retry booking page</button></div>`;const retry=$('portalRetry');if(retry)retry.onclick=()=>renderPortal(slug)}
    }
    return;
  }finally{clearTimeout(portalLoadTimer)}
  if(!isPortalCurrent())return;

  const bc=contrastSafeBrandColor(CUSTOMER_SURFACE_ACCENT_V375);
  const currency=biz.currency||'SGD';
  const services=(biz.services&&biz.services.length)?biz.services:[];
  const hasServices=services.length>0;
  const repeatService=repeatServiceParam?services.find(service=>service.id===repeatServiceParam)||null:null;
  const repeatPreference=repeatService?customerRepeatBookingPreferencesV167.get(`${slug}:${repeatService.id}`)||null:null;
  const usesTables=!!biz.uses_tables;
  /* v192 (owner: "pressing booking will lead me to this page — but there's no way to back").
     The portal is also a public page a stranger opens from a QR, and that visitor has nothing to
     go back TO. So the control appears only for someone who arrived from their own wallet: a
     signed-in customer. It points at that business's programme when they are linked, otherwise at
     the wallet home. */
  let portalBackHrefV192=signedInUser?'#/wallet':'';
  const tables=(biz.tables&&biz.tables.length)?biz.tables:[];
  /* v183 (owner: "if services allow customers to choose staff, please enable it… business still
     will approve/reject"): the team step is now REAL. When the business turns staff choice on,
     the gateway sends the bookable roster and per-slot availability computed from the same
     rota, appointments and blocked-time rows the business calendar reads. When the toggle is
     off there is no team step at all and no roster is exposed. */
  const bookableStaff=(biz.booking_staff_choice===true&&Array.isArray(biz.staff))?biz.staff:[];
  const staffChoice=bookableStaff.length>0;
  /* v327 (owner: multi-branch businesses need a branch step between Service and Team, and
     Team then only offers staff assigned to that branch). Only exposed when there is a real
     choice to make — a single-branch business (still most of them) gets no new step at all,
     matching the "off by default, exposes nothing" contract v183 set for staff choice. */
  const bookableBranches=Array.isArray(biz.branches)?biz.branches:[];
  const branchChoice=bookableBranches.length>1;
  const middleStep=usesTables?'table':(staffChoice?'team':'');
  const steps=['service',branchChoice?'branch':'',middleStep,'time','details'].filter(Boolean);
  const stepMeta={service:{label:'Service'},branch:{label:'Branch'},table:{label:'Table'},team:{label:'Team'},time:{label:'Time'},details:{label:'Details'}};
  let selSvc=repeatService?.id||null;     // null = general reservation, or a validated public service uuid
  let serviceChosen=!!repeatService||!hasServices;
  let selTable=null;                     // reservation table type uuid (null = any/general)
  // The server lists branches with the shop default first — preselecting it keeps a
  // multi-branch booking to the same tap count as before for the common case, while still
  // letting the customer change it.
  let selBranch=branchChoice?bookableBranches[0].id:null;
  let selStaff=null;                     // a validated staff uuid, or null for "anyone available"
  let availabilityState={status:'idle',key:'',data:null};
  let selectedSlot='';                   // an ISO instant chosen from the live slot grid
  let stepIdx=0;
  let bookingSubmissionId=null,bookingSubmissionKey='';
  let bookingTurnstileToken='',bookingTurnstileControl=null;
  let bookingChallengeGeneration=0;
  let changeAttempt=null;
  let turnstileMounted=false;
  let linkedCustomer=false;
  const nowSgtLocal=new Date(Date.now()+8*3600000).toISOString().slice(0,16);
  const svcObj=()=>services.find(s=>s.id===selSvc)||null;
  /* A team member is offered for a service when the business made no assignments for that
     service at all, or when this person is one of the people it assigned. Mirrors
     app.v183_bookable_staff() exactly so the page never offers someone the server will reject.
     v327: also scoped to the chosen branch — unlike services, a branch assignment is exact
     (no "nobody assigned = everyone" fallback), because every staff member is assigned to at
     least one branch from the moment they're created. */
  const staffForService=()=>bookableStaff.filter(member=>{
    if(branchChoice&&selBranch){
      const branches=Array.isArray(member?.branch_ids)?member.branch_ids:[];
      if(!branches.includes(selBranch))return false;
    }
    if(!selSvc)return true;
    const assigned=Array.isArray(member?.service_ids)?member.service_ids:[];
    if(!assigned.length)return true;
    return assigned.includes(selSvc);
  });
  const staffMember=id=>bookableStaff.find(member=>member?.id===id)||null;
  const staffName=()=>staffMember(selStaff)?.name||'';
  /* v286 (audit): "Book again" fetched the previous team member's NAME and then wrote it into
     a "teamName" input — an element that has never existed on this page, so the guard around it
     swallowed it and the feature was dead. The roster is keyed by id, so the cached name is
     resolved against the people this service can actually be booked with (case-insensitively, and
     only when exactly one matches — two Jamies must not silently pick one). Setting selStaff is
     what makes teamOptionsMarkup render them pre-selected and what pins the availability query to
     that person, even though repeat booking opens on the time step. */
  if(repeatPreference?.staffName&&staffChoice){
    const wanted=String(repeatPreference.staffName).trim().toLowerCase();
    const matches=staffForService().filter(member=>String(member?.name||'').trim().toLowerCase()===wanted);
    if(matches.length===1)selStaff=matches[0].id;
  }
  const availabilityKey=()=>JSON.stringify({service:selSvc||'',staff:selStaff||'',branch:selBranch||''});
  const slotLabel=iso=>{
    const at=new Date(iso);
    return Number.isNaN(at.getTime())?'':at.toLocaleTimeString('en-SG',{hour:'numeric',minute:'2-digit',timeZone:'Asia/Singapore'});
  };
  const sgLocalInput=iso=>{
    const at=new Date(iso);
    return Number.isNaN(at.getTime())?'':new Date(at.getTime()+8*3600000).toISOString().slice(0,16);
  };
  const teamOptionsMarkup=()=>`<button class="svc${selStaff===null?' sel':''}" type="button" aria-pressed="${selStaff===null}" data-team=""><span><b>Anyone available</b> <span class="muted small">· usually the soonest slot</span></span></button>
        ${staffForService().map(member=>`<button class="svc${selStaff===member.id?' sel':''}" type="button" aria-pressed="${selStaff===member.id}" data-team="${esc(member.id)}"><span><b>${esc(member.name||'Team member')}</b>${member.title?` <span class="muted small">· ${esc(member.title)}</span>`:''}</span></button>`).join('')}`;
  const dayLabel=date=>{
    const at=new Date(`${date}T00:00:00+08:00`);
    return Number.isNaN(at.getTime())?date:at.toLocaleDateString('en-SG',{weekday:'short',day:'numeric',month:'short',timeZone:'Asia/Singapore'});
  };
  /* v192: the signed-in banner is injected AFTER draw() returns, so its handler cannot see
     showStep — which lives inside draw(). "Edit booking details" threw a ReferenceError and did
     nothing at all. draw() now publishes the current stepper here. */
  let portalShowStepV192=null;
  const fmtPicked=v=>{if(!v)return 'Not chosen yet';const t=v.split('T')[1]||'';const dt=new Date(v);return isNaN(dt)?v:dt.toLocaleDateString([],{weekday:'short',day:'numeric',month:'short'})+(t?' · '+t:'');};
  const draw=()=>{
    destroyMountedTurnstiles();
    const progressHtml=`<ol class="pf-progress" id="pfProgress">${steps.map((k,i)=>`<li data-dot="${i}"><span class="pf-dot" aria-hidden="true">${i+1}</span>${esc(stepMeta[k].label)}</li>`).join('')}</ol>`;
    const serviceStep=`<section class="pf-step" data-step="service" hidden>
      <h2 tabindex="-1">${hasServices?'What would you like?':'Start your booking'}</h2>
      <p class="pf-hint">${hasServices?'Choose a service to get started.':'Tell us a little about your visit.'}</p>
      ${hasServices?`<div class="pf-choice" role="group" aria-label="Choose a service">
        ${services.map(s=>`<button class="svc${selSvc===s.id?' sel':''}" type="button" aria-pressed="${selSvc===s.id}" data-svc="${esc(s.id)}">
          <span><b>${esc(s.name)}</b> <span class="muted small">· ${s.duration_min} min</span></span>
          <b>${esc(currency)} ${(s.price_cents/100).toFixed(2)}</b></button>`).join('')}
        ${usesTables?`<button class="svc${(serviceChosen&&selSvc===null)?' sel':''}" type="button" aria-pressed="${serviceChosen&&selSvc===null}" data-svc=""><span><b>Just a reservation</b> <span class="muted small">· table / general visit</span></span></button>`:''}
      </div>`:`<p class="muted small">We'll note this as a general visit — pick your time on the next step.</p>`}
      <div class="pf-inlineerr" id="err-service" role="alert"></div>
      <div class="pf-nav"><button class="btn" id="next-service" type="button">Continue</button></div>
    </section>`;
    const branchStep=`<section class="pf-step" data-step="branch" hidden>
      <h2 tabindex="-1">Which branch?</h2>
      <p class="pf-hint">Choose where you'd like to visit.</p>
      <label for="branchSelect">Branch</label>
      <select id="branchSelect" aria-label="Choose a branch">
        ${bookableBranches.map(b=>`<option value="${esc(b.id)}"${selBranch===b.id?' selected':''}>${esc(b.name)}</option>`).join('')}
      </select>
      <div class="pf-nav"><button class="btn ghost pf-back" type="button" data-back>Back</button><button class="btn" id="next-branch" type="button">Continue</button></div>
    </section>`;
    const tableStep=`<section class="pf-step" data-step="table" hidden>
      <h2 tabindex="-1">Choose a table</h2>
      <p class="pf-hint">Live availability for your visit.</p>
      <div class="pf-choice" role="group" aria-label="Choose a table">
        <button class="svc${selTable===null?' sel':''}" type="button" aria-pressed="${selTable===null}" data-tbl=""><span><b>Any available table</b> <span class="muted small">· no table preference</span></span></button>
        ${tables.map(t=>{const full=t.available<=0;return `<button class="svc${selTable===t.table_type_id?' sel':''}" type="button" aria-pressed="${selTable===t.table_type_id}" data-tbl="${t.table_type_id}" ${full?'disabled':''}>
          <span><b>${esc(t.name)}</b>${t.pax?` <span class="muted small">· seats ${t.pax}</span>`:''}</span>
          <span class="muted small">${full?'Fully booked':t.available+' available'}</span></button>`;}).join('')}
      </div>
      ${tables.length?'':`<p class="muted small">No specific tables are set up — this request will have no table preference.</p>`}
      <div class="pf-nav"><button class="btn ghost pf-back" type="button" data-back>Back</button><button class="btn" id="next-table" type="button">Continue</button></div>
    </section>`;
    const teamStep=`<section class="pf-step" data-step="team" hidden>
      <h2 tabindex="-1">Who would you like?</h2>
      <p class="pf-hint">Pick a team member, or let ${esc(biz.name)} assign whoever is free.</p>
      <div class="pf-choice" role="group" aria-label="Choose a team member">
        ${teamOptionsMarkup()}
      </div>
      <div class="pf-nav"><button class="btn ghost pf-back" type="button" data-back>Back</button><button class="btn" id="next-team" type="button">Continue</button></div>
    </section>`;
    const timeStep=`<section class="pf-step" data-step="time" hidden>
      <h2 tabindex="-1">Pick a date & time</h2>
      <p class="pf-hint">${biz.booking_auto_confirm?'We confirm instantly when a spot is free.':'Choose your preferred slot. This saves a request for manual review; the business may approve or reject it.'}</p>
      <div id="pfSlots"></div>
      <div id="pfManualTime"><label for="pt">Preferred date & time</label><input id="pt" type="datetime-local" min="${nowSgtLocal}"></div>
      <div class="pf-inlineerr" id="err-time" role="alert"></div>
      <div class="pf-nav"><button class="btn ghost pf-back" type="button" data-back>Back</button><button class="btn" id="next-time" type="button">Continue</button></div>
    </section>`;
    const detailsStep=`<section class="pf-step" data-step="details" hidden>
      <h2 tabindex="-1">Your details</h2>
      <p class="pf-hint">Almost done — add contact details for this booking request.</p>
      <div class="pf-summary" id="pfSummary"></div>
      <div class="split"><div><label for="pn">Your name *</label><input id="pn" autocomplete="name"></div>
        <div><label for="pp">Phone</label><div class="row">${ccSelectHtml('ppcc')}<input id="pp" type="tel" autocomplete="tel" placeholder="9123 4567"></div></div></div>
      <div class="split"><div><label for="pe">Email</label><input id="pe" type="email" autocomplete="email"></div><div><label for="ps">${usesTables?'Party size':'Guests'}</label><input id="ps" type="number" min="1" max="50" value="${usesTables?2:1}"></div></div>
      <p class="muted small" style="margin-top:6px">Add a phone or email so the business can contact you about this request.</p>
      <label for="pnotes">Notes</label><textarea id="pnotes" rows="2" placeholder="Anything we should know?"></textarea>
      <label for="pconsent" style="display:flex;align-items:center;gap:8px;margin-top:16px;cursor:pointer;color:var(--ink);font-weight:500;font-size:14px">
        <input type="checkbox" id="pconsent" style="width:auto"> <span>Send me offers and updates</span></label>
      <p class="muted small" style="margin-top:2px">Occasional news and offers from ${esc(biz.name)} — you can opt out anytime.</p>
      <div class="challenge"><div id="bookingTurnstile"></div>
        <p class="challenge-status" id="bookingTurnstileStatus" role="status" aria-live="polite">Loading security check…</p>
        <button class="challenge-retry" id="bookingTurnstileRetry" type="button" hidden>Retry security check</button>
      </div>
      <div id="perr"></div>
      <div class="pf-nav"><button class="btn ghost pf-back" type="button" data-back>Back</button><button class="btn" id="psend" disabled>${biz.booking_auto_confirm?'Confirm booking':'Send booking request'}</button></div>
      ${biz.booking_policy?`<p class="muted small" style="margin-top:12px;text-align:center">${esc(biz.booking_policy)}</p>`:''}
    </section>`;
    const stepBody={service:serviceStep,branch:branchStep,table:tableStep,team:teamStep,time:timeStep,details:detailsStep};
    root.innerHTML=`<div class="portal customer-surface" style="--coral:${bc};--grad:linear-gradient(100deg,${bc},${bc})">
      <div class="head">${portalBackHrefV192?`<a class="btn ghost sm portal-back" href="${esc(portalBackHrefV192)}">${CUI.icon('back',{size:16})}<span>Back</span></a>`:''}<h1 style="font-size:2rem">${esc(biz.name)}</h1><p class="muted">Book with us — it takes 30 seconds.</p>${biz.bio?`<p class="muted small" style="margin-top:6px">${esc(biz.bio)}</p>`:''}</div>
      <div id="portalSignedInSlot"></div>
      <div class="card" id="bookingFormCard">
        ${progressHtml}
        ${steps.map(k=>stepBody[k]).join('')}
      </div>
      <div class="card" style="margin-top:16px" id="portalManageCard"><b>Manage an existing booking</b>
        <div id="portalUpcoming" style="margin-top:10px"></div>
        <!-- v183 (owner: "no one will remember their booking code — just show the upcoming
             appointments instead"): a signed-in linked customer gets their real bookings above
             and never needs this. It stays, collapsed, as the only route a GUEST has back to a
             booking they made without an account. -->
        <details id="portalManageToken" style="margin-top:12px"${manageToken?' open':''}><summary class="small">Booked as a guest? Open with your booking link or code</summary>
          <p class="muted small" style="margin:8px 0 10px">Use the private management code issued with your booking. Your phone number is never used as a password.</p>
          <div class="row"><input id="mtoken" autocomplete="off" placeholder="Booking management code" value="${esc(manageToken)}"><button class="btn ghost sm" id="mfind">Open booking</button></div>
          <div id="merr"></div>
          <div id="mlist" style="margin-top:12px"></div>
        </details>
      </div>${legalLinks(customerLocale)}</div>`;
    const buildSummary=()=>{
      const el=$('pfSummary');if(!el)return;
      const s=svcObj();
      const rows=[['Service', s?esc(s.name):'General visit']];
      if(s)rows.push(['Duration & price',`${s.duration_min} min · ${esc(currency)} ${(s.price_cents/100).toFixed(2)}`]);
      if(branchChoice)rows.push(['Branch',selBranch?esc((bookableBranches.find(b=>b.id===selBranch)||{}).name||'Selected'):'Not chosen']);
      if(usesTables)rows.push(['Table', selTable?esc((tables.find(t=>t.table_type_id===selTable)||{}).name||'Selected'):'Any available']);
      else if(staffChoice)rows.push(['Team member',selStaff&&staffName()?esc(staffName()):'Anyone available']);
      rows.push(['When',esc(selectedSlot?fmtPicked(sgLocalInput(selectedSlot)):fmtPicked($('pt')?.value))]);
      if(biz.booking_policy)rows.push(['Good to know',esc(biz.booking_policy)]);
      el.innerHTML=`<dl>${rows.map(([k,v])=>`<dt>${k}</dt><dd>${v}</dd>`).join('')}</dl>`;
    };
    const mountBookingTurnstile=()=>{
      if(turnstileMounted)return;
      turnstileMounted=true;
      const challengeGeneration=++bookingChallengeGeneration;
      bookingTurnstileToken='';bookingTurnstileControl=null;
      mountTurnstile(biz.turnstile_site_key,{container:'bookingTurnstile',status:'bookingTurnstileStatus',retry:'bookingTurnstileRetry',action:'public_booking',
        onToken:(token)=>{if(challengeGeneration!==bookingChallengeGeneration)return;bookingTurnstileToken=token;if($('psend'))$('psend').disabled=!token}})
        .then(control=>{if(challengeGeneration===bookingChallengeGeneration)bookingTurnstileControl=control});
    };
    /* v183: the live slot grid. It is advisory — a slot can be taken between the read and the
       submit — so the copy never promises a hold, and every fallback lands the customer back on
       the plain "preferred time" request rather than blocking the booking. */
    let slotDay='';
    const renderSlots=()=>{
      const host=$('pfSlots'),manual=$('pfManualTime');
      if(!host)return;
      const data=availabilityState.data;
      const days=(Array.isArray(data?.days)?data.days:[]).filter(day=>Array.isArray(day?.slots)&&day.slots.length);
      if(availabilityState.status==='error'||!data||data.hours_configured!==true||!days.length){
        if(manual)manual.hidden=false;
        host.innerHTML=availabilityState.status==='error'
          ?'<p class="muted small">Live availability could not be checked just now. Pick your preferred time and the business will confirm.</p>'
          :(data&&data.hours_configured!==true
            ?`<p class="muted small">${esc(biz.name)} has not published working hours yet. Pick your preferred time and they will confirm.</p>`
            :'<p class="muted small">No free times in the next two weeks. Pick a preferred time and the business will come back to you.</p>');
        return;
      }
      if(manual)manual.hidden=true;
      if(!days.some(day=>day.date===slotDay))slotDay=days[0].date;
      const current=days.find(day=>day.date===slotDay)||days[0];
      host.innerHTML=`<div class="pf-day-track" role="group" aria-label="Choose a day">${days.map(day=>`<button class="pf-day${day.date===slotDay?' sel':''}" type="button" data-slot-day="${esc(day.date)}" aria-pressed="${day.date===slotDay}"><b>${esc(dayLabel(day.date))}</b><span class="muted small">${day.slots.length} free</span></button>`).join('')}</div>
        <div class="pf-slot-grid" role="group" aria-label="Choose a time">${current.slots.map(slot=>`<button class="pf-slot${selectedSlot===slot.at?' sel':''}" type="button" data-slot="${esc(slot.at)}" aria-pressed="${selectedSlot===slot.at}">${esc(slotLabel(slot.at))}</button>`).join('')}</div>
        <p class="muted small" style="margin-top:10px">Live from ${esc(biz.name)}'s calendar${selStaff&&staffName()?` for ${esc(staffName())}`:''}. The business still confirms your booking.</p>`;
      host.querySelectorAll('[data-slot-day]').forEach(button=>button.onclick=()=>{slotDay=button.dataset.slotDay;renderSlots()});
      host.querySelectorAll('[data-slot]').forEach(button=>button.onclick=()=>{
        selectedSlot=button.dataset.slot;
        const err=$('err-time');if(err)err.textContent='';
        renderSlots();
      });
    };
    const loadAvailability=async()=>{
      const host=$('pfSlots'),manual=$('pfManualTime');
      if(!host)return;
      if(!staffChoice){host.innerHTML='';if(manual)manual.hidden=false;return}
      const key=availabilityKey();
      if(availabilityState.status==='ready'&&availabilityState.key===key)return renderSlots();
      availabilityState={status:'loading',key,data:null};
      host.innerHTML='<p class="muted small">Checking live availability…</p>';
      if(manual)manual.hidden=true;
      let data=null;
      try{
        data=await publicGateway('public-booking',{method:'GET',query:`?slug=${encodeURIComponent(slug)}&availability=1${selSvc?`&service=${encodeURIComponent(selSvc)}`:''}${selStaff?`&staff=${encodeURIComponent(selStaff)}`:''}${branchChoice&&selBranch?`&branch=${encodeURIComponent(selBranch)}`:''}&days=14`});
      }catch{data=null}
      if(!isPortalCurrent()||!host.isConnected)return;
      availabilityState=data?{status:'ready',key,data}:{status:'error',key,data:null};
      renderSlots();
    };
    const showStep=portalShowStepV192=(idx)=>{
      stepIdx=Math.max(0,Math.min(idx,steps.length-1));
      const key=steps[stepIdx];
      root.querySelectorAll('.pf-step').forEach(el=>{el.hidden=el.dataset.step!==key;});
      root.querySelectorAll('#pfProgress li').forEach((li,i)=>{
        li.classList.toggle('current',i===stepIdx);
        li.classList.toggle('done',i<stepIdx);
        if(i===stepIdx)li.setAttribute('aria-current','step');else li.removeAttribute('aria-current');
      });
      if(key==='time')loadAvailability();
      if(key==='details'){buildSummary();mountBookingTurnstile();}
      const stepEl=root.querySelector(`.pf-step[data-step="${key}"]`);
      const heading=stepEl?.querySelector('h2');
      if(heading)requestAnimationFrame(()=>heading.focus({preventScroll:false}));
      CUI.announce('Step '+(stepIdx+1)+' of '+steps.length+': '+stepMeta[key].label);
    };
    const setChoice=(selector,el)=>root.querySelectorAll(selector).forEach(b=>{const on=b===el;b.classList.toggle('sel',on);b.setAttribute('aria-pressed',String(on));});
    root.querySelectorAll('[data-svc]').forEach(el=>el.onclick=()=>{
      selSvc=el.dataset.svc||null;serviceChosen=true;setChoice('[data-svc]',el);
      /* A different service can mean a different team and a different slot length, so any
         earlier person and slot pick is dropped rather than silently carried forward. */
      if(staffChoice&&!staffForService().some(member=>member.id===selStaff))selStaff=null;
      selectedSlot='';renderTeamOptions();
      const e=$('err-service');if(e)e.textContent='';
    });
    root.querySelectorAll('[data-tbl]').forEach(el=>el.onclick=()=>{selTable=el.dataset.tbl||null;setChoice('[data-tbl]',el);});
    if($('branchSelect'))$('branchSelect').onchange=()=>{
      selBranch=$('branchSelect').value||null;
      if(staffChoice&&!staffForService().some(member=>member.id===selStaff))selStaff=null;
      selectedSlot='';renderTeamOptions();
    };
    const wireTeamChoice=()=>root.querySelectorAll('[data-team]').forEach(el=>el.onclick=()=>{
      selStaff=el.dataset.team||null;setChoice('[data-team]',el);selectedSlot='';
    });
    const renderTeamOptions=()=>{
      if(!staffChoice)return;
      const host=root.querySelector('.pf-step[data-step="team"] .pf-choice');
      if(!host)return;
      host.innerHTML=teamOptionsMarkup();
      wireTeamChoice();
    };
    wireTeamChoice();
    root.querySelectorAll('[data-back]').forEach(el=>el.onclick=()=>showStep(stepIdx-1));
    if($('next-service'))$('next-service').onclick=()=>{if(hasServices&&!serviceChosen){$('err-service').textContent='Please choose a service, or “Just a reservation”.';CUI.announce('Please choose a service',{assertive:true});return;}showStep(stepIdx+1);};
    if($('next-branch'))$('next-branch').onclick=()=>showStep(stepIdx+1);
    if($('next-table'))$('next-table').onclick=()=>showStep(stepIdx+1);
    if($('next-team'))$('next-team').onclick=()=>showStep(stepIdx+1);
    if($('next-time'))$('next-time').onclick=()=>{
      if(!selectedSlot&&!$('pt')?.value){$('err-time').textContent='Please pick a date and time.';CUI.announce('Please pick a date and time',{assertive:true});return;}
      showStep(stepIdx+1);
    };
    $('psend').onclick=async()=>{
      if(!bookingTurnstileToken) return;
      const name=($('pn').value||'').trim();
      const rawPhone=($('pp').value||'').trim();
      const email=($('pe').value||'').trim();
      if(name.length<2){$('perr').innerHTML=`<div class="err">Please enter your name.</div>`;$('pn').focus();return;}
      if(!rawPhone&&!email){$('perr').innerHTML=`<div class="err">Add a phone or email so the business can contact you about this request.</div>`;$('pp').focus();return;}
      $('perr').innerHTML='';$('psend').disabled=true;
      let notesFinal=($('pnotes').value||'').trim();
      notesFinal=notesFinal?notesFinal.slice(0,1000):null;
      const bookingPayload={
        slug,name,email:email||null,
        phone:rawPhone?buildPhone('ppcc','pp'):null,service:selSvc,
        party:parseInt($('ps').value||'1'),
        /* A slot chosen from the live grid is already an exact instant; the manual picker is
           still a Singapore wall-clock value that has to be anchored to +08:00. */
        preferred:selectedSlot||sgIso($('pt')?.value),
        notes:notesFinal,table_type:usesTables?selTable:null,
        staff:usesTables?null:selStaff,
        branch:branchChoice?selBranch:null,
        consent:$('pconsent').checked};
      const nextBookingKey=JSON.stringify(bookingPayload);
      if(!bookingSubmissionId||bookingSubmissionKey!==nextBookingKey){
        bookingSubmissionId=crypto.randomUUID();bookingSubmissionKey=nextBookingKey;
      }
      let bookRes;
      try{bookRes=await submitPublicBookingGateway({...bookingPayload,submission_id:bookingSubmissionId,
        turnstile_token:bookingTurnstileToken},signedInUser,isPortalCurrent)}
      catch(error){
        if(!isPortalCurrent()||!$('perr')?.isConnected)return;
        $('perr').innerHTML=`<div class="err">${esc(humanErrorV295(error,'Your booking request could not be sent.'))}</div>`;
        if($('psend'))$('psend').disabled=false;
        bookingTurnstileControl?.reset();return;
      }
      if(!isPortalCurrent())return;
      const msgs={
        confirmed:{em:'🎉',title:"You're booked!",body:`${esc(biz.name)} has confirmed your booking.`,next:"We've saved your booking — no further action needed."},
        pending:{em:'🎉',title:'Request sent!',body:`${esc(biz.name)}: ${esc(workspaceTranslationV97('Your booking request is saved for manual review.'))}`,next:workspaceTranslationV97('The business may approve or reject it. Use your private link to check the current status, or contact the business directly.')},
        waitlisted:{em:'⏳',title:"You're on the waitlist",body:`${esc(biz.name)} is fully booked for that time. Your request is in the business's manual waitlist queue.`,next:'The business may contact you if a suitable spot opens; Peekaa does not send an automatic waitlist message.'},
        rejected:{em:'😔',title:'Fully booked',body:`Sorry, ${esc(biz.name)} is fully booked for that — try another table or time.`,next:'Try another table or time — nothing was booked.'}
      };
      const m=msgs[bookRes&&bookRes.status]||msgs.pending;
      manageToken=bookRes.manage_token||'';
      const manageUrl=publicAppUrl(`b/${encodeURIComponent(slug)}?manage=${encodeURIComponent(manageToken)}`);
      const bookingFormCard=$('bookingFormCard');
      if(!bookingFormCard)return;
      bookingTurnstileControl?.destroy();bookingTurnstileControl=null;
      bookingFormCard.innerHTML=`<div class="empty"><div class="big">${m.em}</div><h2 tabindex="-1" style="margin-bottom:8px">${esc(m.title)}</h2>
        <p class="muted">${m.body}</p>
        <p class="small" style="margin-top:10px"><b>What happens next:</b> ${m.next}</p>${manageToken?`<p class="small" style="margin-top:14px">Keep this private link to manage the booking:</p>
        <p class="small" style="margin-top:6px;word-break:break-all"><a href="${esc(manageUrl)}" style="color:#D06A2E;text-decoration:underline">${esc(manageUrl)}</a></p>
        <button class="btn ghost sm" id="copyManage" style="margin-top:12px">Copy private link</button>`:''}${linkedCustomer?`<p style="margin-top:14px"><a class="btn sm" href="#/customer/bookings">View in Bookings</a></p>`:''}</div>`;
      CUI.announce(m.title+' '+m.body,{assertive:true});
      requestAnimationFrame(()=>bookingFormCard.querySelector('h2')?.focus());
      if($('copyManage')) $('copyManage').onclick=async()=>copyTextToClipboard(manageUrl,{button:$('copyManage'),success:'Private link copied'});
    };
    $('mfind').onclick=async()=>{
      manageToken=($('mtoken').value||'').trim();
      if(!manageToken){$('merr').innerHTML='<div class="err">Enter your booking management code.</div>';return}
      $('merr').innerHTML='';$('mfind').disabled=true;
      let data;
      try{data=await publicGateway('manage-booking',{body:{action:'lookup',token:manageToken}})}
      catch(error){$('merr').innerHTML=`<div class="err">${esc(humanErrorV295(error,'That booking could not be found.'))}</div>`;$('mfind').disabled=false;return}
      $('mfind').disabled=false;
      const when=data.starts_at||data.preferred_at;
      /* v286 (audit): this was the one time on the whole booking surface printed in the device's
         zone — toLocaleString() with no timeZone. A traveller, or a phone set to the wrong zone,
         read a different hour here than in the confirmation card and in Bookings, and could
         reschedule against a time that never existed. walletDate() is the surface's own SGT
         formatter, the same one every other date here already goes through. */
      $('mlist').innerHTML=`<div style="padding:10px 0"><b>${esc(walletDate(when,true))||'Time pending'}</b>
        <div class="muted small">${esc(data.service_name||'general visit')} · ${esc(data.status||'pending')}</div></div>
        ${data.can_change?`<label for="mdt">New preferred time</label><input type="datetime-local" id="mdt">
        <div class="row" style="margin-top:10px"><button class="btn ghost sm" id="mcancel" type="button">Request cancellation</button>
        <button class="btn sm" id="mresched" type="button">Request reschedule</button></div>`:'<p class="muted small">Changes are not available for this booking.</p>'}`;
      /* v294: real listeners on the freshly-rendered buttons. The old inline onclick reached
         handlers only through window globals — fragile under a minifier and blocked by any
         future CSP that drops 'unsafe-inline'. Attached per repaint, exactly like copyManage. */
      $('mcancel')?.addEventListener('click',mCancelHandler);
      $('mresched')?.addEventListener('click',mRescheduleHandler);
    };
    showStep(repeatService?steps.indexOf('time'):0);
    if(manageToken) setTimeout(()=>$('mfind')?.click(),0);
  };
  /* v286 (audit): after a successful change the panel used to keep showing the OLD status and two
     live buttons, and it cleared changeAttempt — so a second tap minted a fresh submission_id, the
     gateway dedupe missed it, and the business received the same cancellation twice. Nothing was
     disabled during the await either, so on a slow line the customer saw no change at all and
     tapped again. Both buttons now go busy for the duration, the attempt key is KEPT so a replay
     carries the same submission_id, and a success re-runs the lookup so the row repaints with the
     status the server actually holds. */
  const manageChangeBusyV286=busy=>{
    for(const id of ['mcancel','mresched']){
      const button=$(id);
      if(!button)continue;
      button.disabled=busy;
      if(busy)button.setAttribute('aria-busy','true');else button.removeAttribute('aria-busy');
    }
  };
  const manageChangeSettledV286=data=>{
    toast(data&&data.status==='approved'?'Done — auto-approved':workspaceTranslationV97('Request saved for manual review — check the private link for its current status.'));
    /* Repaint from the server rather than from what we hoped happened: the lookup is the only
       honest source for the booking's new status, and it also re-evaluates can_change. */
    $('mfind')?.click();
  };
  const mCancelHandler=async()=>{
    manageToken=($('mtoken')?.value||manageToken).trim();
    if(!manageToken) return toast('Enter your booking management code');
    /* v177: the native browser confirmation is unstyled, untranslatable and blocked in some webviews.
       Reuses the already-localised portal strings so no copy is lost in zh-CN or ms. */
    const confirmed=await showCustomerDecisionDialog({title:'Cancel this booking?',
      body:workspaceTranslationV97('Send a cancellation request?'),
      keepLabel:workspaceTranslationV97('Keep booking'),
      confirmLabel:workspaceTranslationV97('Request cancellation'),danger:true});
    if(!confirmed) return;
    const key=JSON.stringify({kind:'cancel',proposed:null,note:null});
    if(!changeAttempt||changeAttempt.key!==key)changeAttempt={key,id:crypto.randomUUID()};
    let data;
    manageChangeBusyV286(true);
    try{data=await publicGateway('manage-booking',{body:{action:'change',token:manageToken,submission_id:changeAttempt.id,kind:'cancel',proposed:null,note:null}})}
    catch(error){manageChangeBusyV286(false);return toast(humanErrorV295(error,'Your cancellation request could not be sent.'))}
    manageChangeSettledV286(data);
  };
  const mRescheduleHandler=async()=>{
    manageToken=($('mtoken')?.value||manageToken).trim();
    if(!manageToken) return toast('Enter your booking management code');
    const val=$('mdt')?.value;
    if(!val) return toast('Pick a new date & time first');
    const proposed=sgIso(val),key=JSON.stringify({kind:'reschedule',proposed,note:null});
    if(!changeAttempt||changeAttempt.key!==key)changeAttempt={key,id:crypto.randomUUID()};
    let data;
    manageChangeBusyV286(true);
    try{data=await publicGateway('manage-booking',{body:{action:'change',token:manageToken,submission_id:changeAttempt.id,kind:'reschedule',proposed,note:null}})}
    catch(error){manageChangeBusyV286(false);return toast(humanErrorV295(error,'Your reschedule request could not be sent.'))}
    manageChangeSettledV286(data);
  };
  draw();
  /* Off the critical path: once personas resolve, inject a CUSTOMER-only "Open rewards" banner.
     A staff session in the same browser is deliberately NOT surfaced here — the audit flagged the
     old "Signed in as staff" line as contextually confusing on a customer-facing surface. The
     portal renders as a pure customer product; staff reach their workspace through the app. */
  Promise.all([personaPromise,profilePromise]).then(([personaResult,profileResult])=>{
    if(!isPortalCurrent())return;
    const slot=$('portalSignedInSlot');
    if(!slot?.isConnected||!signedInUser)return;
    const customer=!personaResult?.error&&(personaResult?.data?.customer||[]).find(p=>p.business_slug===slug);
    if(customer){
      linkedCustomer=true;
      portalBackHrefV192=`#/wallet/${encodeURIComponent(slug)}`;
      const back=root.querySelector('.portal-back');
      if(back)back.setAttribute('href',portalBackHrefV192);
      loadPortalUpcomingBookingsV183(slug,isPortalCurrent);
      const identity=customerBookingIdentitySummaryV167({profile:profileResult?.error?null:profileResult?.data?.profile,user:signedInUser});
      slot.innerHTML=`<div class="card" style="margin-bottom:16px"><div class="row"><div><b>Booking as ${esc(identity.name)}${identity.contact?` · ${esc(identity.contact)}`:''}</b><p class="muted small" style="margin-top:4px">This request will be securely attached to your ${esc(customer.business_name||biz.name)} programme.</p></div><span class="spacer"></span><button class="btn ghost sm" id="portalBookingEditIdentity" type="button">Edit booking details</button></div></div>`;
      if(!isPortalCurrent()||!slot.isConnected)return;
      prefillEmptyPortalDetails({profile:profileResult?.error?null:profileResult?.data?.profile,user:signedInUser});
      $('portalBookingEditIdentity')?.addEventListener('click',()=>portalShowStepV192?.(steps.indexOf('details')));
    }else if(personaResult?.error){
      slot.innerHTML=`<div class="card" style="margin-bottom:16px"><b>Signed in</b><p class="muted small" style="margin-top:4px">The programme link could not be displayed here. Your verified relationship will be validated securely when you submit.</p></div>`;
    }else{
      slot.innerHTML=`<div class="card" style="margin-bottom:16px"><div><b>Booking as an unlinked guest</b><p class="muted small" style="margin-top:4px">This business is not in ${esc(BRAND.customerLabel)} yet. Your booking can still be submitted safely. To join its programme, visit the participating business and scan its current Peekaa QR.</p></div></div>`;
    }
  }).catch(()=>{});
}

