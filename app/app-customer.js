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
  overlay.innerHTML=`<section class="modal-card"><div class="row"><div style="text-align:left"><h2 id="customerPromotionQrTitle">${esc(promotionName||'Offer')}</h2><p class="muted small" style="margin-top:5px">Show this code to ${esc(businessName||'the team')} at the counter.</p></div><span class="spacer"></span><button class="btn ghost sm" id="customerPromotionQrClose" type="button" aria-label="Close offer code">${CUI.icon('close',{size:18})}</button></div>
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
function showPendingRedemptionQr({intent,businessName,rewardName,onClose=()=>{}}={}){
  const token=String(intent?.qr_token||'');
  if(!token)return;
  activeCustomerRedemptionCleanup({restoreFocus:false});
  const overlay=document.createElement('div');
  overlay.className='modal customer-redemption-modal';overlay.setAttribute('role','dialog');
  overlay.setAttribute('aria-modal','true');overlay.setAttribute('aria-labelledby','customerRedemptionQrTitle');
  overlay.innerHTML=`<section class="modal-card"><div class="row"><div style="text-align:left"><h2 id="customerRedemptionQrTitle">${esc(rewardName||'Redeem reward')}</h2><p class="muted small" style="margin-top:5px">${esc(businessName||'The business')} must scan this code to complete the redemption.</p></div><span class="spacer"></span><button class="btn ghost sm" id="customerRedemptionQrClose" type="button" aria-label="Close redemption QR">${CUI.icon('close',{size:18})}</button></div>
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
  const onVisibilityChange=()=>{if(document.visibilityState==='visible')updateCountdown()};
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
      qr.innerHTML=CUI.icon('check',{size:76});
      panel.classList.add('customer-redemption-complete');
      pill.className='pill ok';pill.textContent='Redeemed';
      status.setAttribute('aria-live','assertive');
      status.textContent=`Redeemed!${points?` ${points} points were used for`:''} ${rewardName||'your reward'} at ${businessName||'this business'}.`;
      customerSuccessCue();
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
  const schedulePoll=(delay=1500)=>{if(!closed&&!terminal)pollTimer=setTimeout(reconcileRedemptionState,delay)};
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
    <span class="spacer"></span><button class="btn ghost sm" id="growthOfferQrClose" type="button" aria-label="Close offer QR">${CUI.icon('close',{size:18})}</button></div>
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
  };
  activeCustomerRedemptionCleanup=close;
  deactivateDialog=CUI.activateDialog(overlay,{onClose:close,initialFocus:'#growthOfferQrDone'});
  overlay.querySelector('#growthOfferQrClose').onclick=close;
  overlay.querySelector('#growthOfferQrDone').onclick=close;
  overlay.addEventListener('click',event=>{if(event.target===overlay)close()});
  overlay.querySelector('#growthOfferQrDone').focus();
}
/* ---------- customer wallet ---------- */
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
    </header>${body}<footer class="customer-entry-footer"><a class="customer-business-link" href="/business">Business sign in</a>${legalLinks()}</footer></div></main>`;
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
    <button class="btn" id="customerOtpVerify" type="button" style="width:100%;margin-top:16px">${CUI.icon('check',{size:18})}<span>${recovering?'Verify and reset password':'Verify and create account'}</span></button>
    <div style="margin-top:14px">${authChallengeHtml()}</div>
    <button class="btn ghost" id="customerOtpResend" type="button" disabled style="width:100%;margin-top:10px">Resend available in 30 seconds</button>
    <button class="btn ghost" id="customerOtpVerifyBack" type="button" style="width:100%;margin-top:10px">${CUI.icon('back',{size:18})}<span>Back</span></button>
  </section>`);
  $('customerOtpVerifyBack').onclick=()=>renderCustomerOtpStart(isRouteCurrent,purpose);
  let resendCaptcha='',resendControl=null,seconds=30;
  mountTurnstile(AUTH_TURNSTILE_SITE_KEY,{container:'authTurnstile',status:'authTurnstileStatus',retry:'authTurnstileRetry',action:'frenly_customer_otp',
    onToken:(token)=>{if(isRouteCurrent())resendCaptcha=token;}}).then(control=>{
      if(!isRouteCurrent()||!$('customerOtpVerify')?.isConnected){control?.destroy();return}
      resendControl=control;
    });
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
    if(!available||!resendCaptcha){
      otpError.innerHTML='<div class="err">Customer mobile verification is unavailable. Please return and try again later.</div>';return;
    }
    resend.disabled=true;
    const options={captchaToken:resendCaptcha};if(channel==='whatsapp')options.channel='whatsapp';
    const {error}=recovering
      ?await sb.auth.signInWithOtp({phone,options:{...options,shouldCreateUser:false}})
      :await sb.auth.resend({type:'sms',phone,options});
    if(!isRouteCurrent()||!resend.isConnected||!otpError.isConnected)return;
    resendCaptcha='';resendControl?.reset();
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
    <button class="btn" id="customerRecoveryPasswordSave" type="button" style="width:100%;margin-top:18px">${CUI.icon('check',{size:18})}<span>Save new password</span></button>
    <button class="btn ghost" id="customerRecoveryPasswordBack" type="button" style="width:100%;margin-top:10px">${CUI.icon('back',{size:18})}<span>Cancel and return to sign in</span></button>
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
    <div style="margin-top:14px">${authChallengeHtml()}</div>
    <button class="btn" id="customerPasswordSignIn" type="submit" disabled style="width:100%;margin-top:16px">${CUI.icon('forward',{size:18})}<span>Checking…</span></button>
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
  let captchaToken='',captchaControl=null;
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
  mountTurnstile(AUTH_TURNSTILE_SITE_KEY,{container:'authTurnstile',status:'authTurnstileStatus',retry:'authTurnstileRetry',action:'frenly_customer_password',
    onToken:(token)=>{
      if(!isRouteCurrent()||!signIn.isConnected)return;
      captchaToken=token;signIn.disabled=!token;passkeyButton.disabled=!passkeySupported||!token;
      /* v193: "Checking…" claimed the APP was busy. Until a token arrives the app is waiting for
         the security check — and if that check is a checkbox, for the person. */
      signIn.querySelector('span').textContent=token?'Sign in':'Waiting for security check…';
      if(installedApp&&passkeySupported&&!customerAutomaticPasskeyAttempted){
        customerAutomaticPasskeyAttempted=true;
        runPasskeySignIn({automatic:true});
      }
    }}).then(control=>{
      if(!isRouteCurrent()||!signIn.isConnected){control?.destroy();return}
      captchaControl=control;
    });
  const submitSignIn=async()=>{
    const phone=normalizeSingaporeCustomerPhone(phoneInput.value),password=passwordInput.value;
    if(!phone||!password){
      errorHost.innerHTML='<div class="err">Enter your Singapore mobile number and password.</div>';return;
    }
    if(!captchaToken){
      errorHost.innerHTML='<div class="err">Security check is still running. Please wait, or retry the security check if an error appears.</div>';return;
    }
    signIn.disabled=true;
    signIn.querySelector('span').textContent='Signing in…';
    const challenge=captchaToken;captchaToken='';
    passkeyButton.disabled=true;
    const {data,error}=await sb.auth.signInWithPassword({phone,password,options:{captchaToken:challenge}});
    if(!isRouteCurrent()||!signIn.isConnected)return;
    captchaControl?.reset();
    if(error||!data?.user){
      // The captcha gate above already blocks a submit without a fresh token, so the
      // button stays usable — a failed sign-in must not become a dead end.
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
    if(!passkeySupported||!captchaToken){
      if(!automatic){
        passkeyStatus.textContent=passkeySupported
          ?'Complete the security check above first — then Face ID, Touch ID or your passkey.'
          :'Passkeys are not supported in this browser. Sign in with your password.';
      }
      return;
    }
    const challenge=captchaToken;captchaToken='';passkeyButton.disabled=true;signIn.disabled=true;
    passkeyStatus.textContent='Waiting for your device…';
    const {data,error}=await sb.auth.signInWithPasskey({options:{captchaToken:challenge}});
    if(!isRouteCurrent()||!passkeyButton.isConnected)return;
    captchaControl?.reset();
    if(error||!data?.user){
      passkeyStatus.textContent=error?.code==='passkey_disabled'
        ?'Face ID and passkeys aren’t available yet. Use your password.'
        :(automatic?'Passkey sign-in was not completed. Use your password or the Face ID button.':customerPasskeyErrorMessage(error,{action:'sign-in'}));
      return;
    }
    resetClientSessionState({preserveInvitation:true});route();
  };
  passkeyButton.onclick=()=>runPasskeySignIn();
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
      <label class="row" for="customerSignupMarketing" style="align-items:flex-start;margin-top:12px;color:var(--ink);font-weight:500"><input id="customerSignupMarketing" type="checkbox" ${customerRegistrationState.marketingOptedIn?'checked':''} style="width:20px;min-width:20px;min-height:20px;margin-top:1px"> <span><b>Yes — send me offers and updates.</b> Nestly Technologies Pte. Ltd., the company behind ${esc(BRAND.productName)}, and its partners may send me marketing by push notification, in-app message, email, SMS, WhatsApp, phone call and other marketing channels. My name and contact details may be shared with ${esc(BRAND.productName)}’s partners for marketing purposes only. I can turn this off any time in Profile → Communications. ${esc(BRAND.productName)} stops sending straight away. Partners are told to stop within 10 business days. <span class="muted">(Optional)</span></span></label>
    </fieldset>`}
    <fieldset style="border:0;margin-top:18px;padding:0"><legend class="small" style="font-weight:700">Send the verification code by</legend>
      <label class="row" for="customerOtpSms" style="color:var(--ink);font-weight:500"><input id="customerOtpSms" name="customerOtpChannel" type="radio" value="sms" checked style="width:20px;min-width:20px;min-height:20px"> <span>SMS</span></label>
      ${whatsappAvailable?`<label class="row" for="customerOtpWhatsapp" style="margin-top:10px;color:var(--ink);font-weight:500"><input id="customerOtpWhatsapp" name="customerOtpChannel" type="radio" value="whatsapp" style="width:20px;min-width:20px;min-height:20px"> <span>WhatsApp</span></label>`:''}
    </fieldset>
    <div id="customerOtpError" role="alert" aria-live="assertive"></div>
    <div style="margin-top:14px">${authChallengeHtml()}</div>
    <button class="btn" id="customerOtpSend" type="button" disabled style="width:100%;margin-top:16px">${CUI.icon('forward',{size:18})}<span>${recovering?'Send password reset code':'Send account verification code'}</span></button>
    <button class="btn ghost" id="customerOtpBack" type="button" style="width:100%;margin-top:10px">Back to sign in</button>
  </section>`);
  bindPasswordVisibility(root);
  $('customerOtpBack').onclick=()=>{
    resetCustomerRegistrationState();
    renderCustomerPasswordSignIn(isRouteCurrent);
  };
  const send=$('customerOtpSend'),phoneInput=$('customerPhone'),errorHost=$('customerOtpError');
  let captchaToken='',captchaControl=null;
  mountTurnstile(AUTH_TURNSTILE_SITE_KEY,{container:'authTurnstile',status:'authTurnstileStatus',retry:'authTurnstileRetry',action:'frenly_customer_otp',
    onToken:(token)=>{if(isRouteCurrent()&&send.isConnected){captchaToken=token;send.disabled=!token}}})
    .then(control=>{
      if(!isRouteCurrent()||!send.isConnected){control?.destroy();return}
      captchaControl=control;
    });
  send.onclick=async()=>{
    const phone=normalizeSingaporeCustomerPhone(phoneInput.value);
    const channel=document.querySelector('input[name="customerOtpChannel"]:checked')?.value||'sms';
    if(!phone){errorHost.innerHTML='<div class="err">Enter a valid 8-digit Singapore number.</div>';return}
    if(customerPhoneBlockedInProduction(phone)){
      errorHost.innerHTML='<div class="err">Mobile verification is unavailable right now.</div>';return;
    }
    const available=await customerPhoneOtpAvailable(channel);
    if(!isRouteCurrent()||!send.isConnected)return;
    if(!available||!captchaToken){
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
    const challenge=captchaToken;captchaToken='';
    const options={captchaToken:challenge};if(channel==='whatsapp')options.channel='whatsapp';
    const result=recovering
      ?await sb.auth.signInWithOtp({phone,options:{...options,shouldCreateUser:false}})
      :await sb.auth.signUp({phone,password,options});
    if(!isRouteCurrent()||!send.isConnected)return;
    captchaControl?.reset();
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
    <button class="btn" id="customerDestinationRetry" type="button" style="width:100%;margin-top:18px">${CUI.icon('forward',{size:18})}<span>Try destination again</span></button>
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
    <button class="btn" id="customerRegister" type="button" style="width:100%;margin-top:18px">${CUI.icon('check',{size:18})}<span>Create my customer account</span></button>
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

let customerCelebrationSoundEnabled=(()=>{try{return sessionStorage.getItem('nestly.customer.successSound')==='1'}catch{return false}})();
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
  return action==='sign-in'
    ?'Passkey sign-in was not completed. Try again, or use your password.'
    :'Passkey setup was not completed. You can add it later from Profile.';
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
    overlay.innerHTML=`<section class="modal-card" style="max-width:500px"><div class="row appointment-detail-head"><div><h2 id="customerPasskeyPromptTitle">Enable Face ID or Touch ID?</h2><p class="muted small" style="margin-top:5px">Add a passkey on this device so next time you can sign in without typing your password.</p></div><span class="spacer"></span><button class="btn ghost sm" id="customerPasskeyPromptClose" type="button" aria-label="Close passkey setup">${CUI.icon('close',{size:18})}</button></div>
      <div class="appointment-detail-section"><p class="muted small">Your face or fingerprint stays on your device. Peekaa only stores the public passkey needed to recognise this login.</p><p id="customerPasskeyPromptStatus" class="muted small" role="status" aria-live="polite" style="margin-top:10px"></p></div>
      <div class="appointment-detail-actions"><button class="btn" id="customerPasskeyPromptAdd" type="button">${CUI.icon('add',{size:17})}<span>Enable now</span></button><button class="btn ghost" id="customerPasskeyPromptSkip" type="button">Not now</button></div></section>`;
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
      const {error}=await sb.auth.registerPasskey();
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
  $('walletBody').innerHTML=`${customerMyRewardsHeadingV156(cards.length,{scanId:'customerHomeScan'})}
    ${customerProgrammeGridMarkupV96(cards)}`;
  $('customerHomeScan').onclick=openCustomerJoinScanner;
  wireCustomerProgrammeSearchV195($('walletBody'));
  focusCustomerRoute();
}

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
function customerBookingFilterMarkupV195(range={from:'',to:''}){
  const {from,to}=range||{};
  const active=!!(from||to);
  return `<div class="customer-booking-filter" role="group" aria-label="Filter bookings by date">
    ${CUI.icon('appointments',{size:16})}
    <label class="sr-only" for="customerBookingFrom">From date</label>
    <input id="customerBookingFrom" type="date" value="${esc(from||'')}" max="2999-12-31">
    <span aria-hidden="true">–</span>
    <label class="sr-only" for="customerBookingTo">To date</label>
    <input id="customerBookingTo" type="date" value="${esc(to||'')}" max="2999-12-31">
    ${active?`<button class="btn ghost sm" id="customerBookingRangeClear" type="button">Clear</button>`:''}
  </div>`;
}
function customerBookingBusinessLogoV195(group={}){
  const url=customerMediaUrlV95(group?.business_logo),name=String(group?.business_name||'Business');
  return url
    ?`<img class="customer-booking-logo" src="${esc(url)}" alt="" loading="lazy" width="40" height="40">`
    :`<span class="customer-booking-logo customer-booking-logo--fallback" aria-hidden="true">${esc((name[0]||'B').toUpperCase())}</span>`;
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
  const chip=group=>group.bookingEnabled
    ?`<button class="customer-booking-chip" type="button" data-repeat-booking data-business-slug="${esc(group.business_slug)}">${customerBookingBusinessLogoV195(group)}<span class="customer-booking-chip-copy"><b data-merchant-content>${esc(group.business_name)}</b><span class="muted small">Book now</span></span></button>`
    :`<a class="customer-booking-chip customer-booking-chip--quiet" href="#/wallet/${encodeURIComponent(group.business_slug)}">${customerBookingBusinessLogoV195(group)}<span class="customer-booking-chip-copy"><b data-merchant-content>${esc(group.business_name)}</b><span class="muted small">No online booking yet</span></span></a>`;
  const industries=[...new Set(businesses.map(group=>String(group.industry||'').trim()).filter(Boolean))];
  if(industries.length>1){
    const bySector=new Map();
    for(const group of businesses){
      const key=String(group.industry||'').trim()||'Other';
      if(!bySector.has(key))bySector.set(key,[]);
      bySector.get(key).push(group);
    }
    return `<section class="card customer-booking-chooser"><h2>Book with</h2>
      ${[...bySector.entries()].map(([sector,members])=>`<h3 class="customer-booking-sector" data-merchant-content>${esc(sector)}</h3><div class="customer-booking-chips">${members.map(chip).join('')}</div>`).join('')}</section>`;
  }
  return `<section class="card customer-booking-chooser"><h2>Book with</h2><div class="customer-booking-chips">${businesses.map(chip).join('')}</div></section>`;
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
  let currentBookingTab='bookings',currentBookingRange={from:'',to:''};
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
    $('walletBody').innerHTML=`<header class="customer-page-head"><div><h1>Bookings</h1></div><span class="spacer"></span>${customerBookingFilterMarkupV195(currentBookingRange)}</header>
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
    ${groups.length?`<div class="customer-booking-list">${groups.map(group=>`<section class="card customer-booking-business"><div class="wallet-section-head">${customerBookingBusinessLogoV195(group)}<div><h2>${esc(group.business_name)}</h2><p class="muted small">${group.tabRequests.length} request${group.tabRequests.length===1?'':'s'} · ${group.tabAppointments.length} appointment${group.tabAppointments.length===1?'':'s'}</p></div><span class="spacer"></span>${group.bookingEnabled&&group.business_slug?`<button class="btn sm" type="button" data-repeat-booking data-business-slug="${esc(group.business_slug)}">Book again</button>`:group.business_slug?`<a class="btn ghost sm" href="#/wallet/${encodeURIComponent(group.business_slug)}">Open programme</a>`:''}</div>
      ${group.tabRequests.length?`<h3 style="font-size:1rem;margin-top:14px">${esc(requestHeading)}</h3>${group.tabRequests.map(item=>`<div class="wallet-appt"><div><b>${esc(walletDate(item.preferred_at,true)||walletDate(item.created_at,true)||'Preferred time pending')}</b><p class="muted small" style="margin-top:3px">${esc(item.service_name||'Booking request')} · ${esc(String(item.status||'pending').replaceAll('_',' '))}${item.party_size?` · party of ${Number(item.party_size)}`:''}</p></div><span class="spacer"></span><span class="pill ${isActiveCustomerBookingRequest(item)?(item.status==='waitlisted'?'new':'off'):'no'}">${esc(isActiveCustomerBookingRequest(item)?(item.status==='waitlisted'?'Waitlisted':'Pending'):String(item.status||'updated').replaceAll('_',' '))}</span>${isActiveCustomerBookingRequest(item)&&item.request_id?`<button class="btn ghost sm" type="button" data-withdraw-request="${esc(item.request_id)}">Withdraw</button>`:''}</div>`).join('')}`:''}
      ${group.tabAppointments.length?`<h3 style="font-size:1rem;margin-top:14px">${esc(appointmentHeading)}</h3>${group.tabAppointments.map(item=>`<div class="wallet-appt"><div><b>${esc(walletDate(item.starts_at,true)||'Time unavailable')}</b><p class="muted small" style="margin-top:3px">${esc(item.service_name||'Appointment')}${item.branch_name?' · '+esc(item.branch_name):''} · ${esc(String(item.status||'confirmed').replaceAll('_',' '))}</p></div><span class="spacer"></span>${customerBookingChangeActionV286(group,item,changesFeatureEnabled)?`<button class="btn ghost sm walletChange" type="button" data-id="${esc(item.appointment_id)}" data-business-slug="${esc(group.business_slug)}">Change</button>`:group.bookingEnabled&&group.business_slug&&customerBookingAppointmentTabV178(item)!=='bookings'?`<button class="btn ghost sm" type="button" data-repeat-booking data-business-slug="${esc(group.business_slug)}" data-appointment-id="${esc(item.appointment_id)}">Book again</button>`:`<span class="pill ${customerBookingAppointmentTabV178(item)==='cancelled'?'no':'ok'}">Appointment</span>`}</div>`).join('')}`:''}
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
    /* v290 (the road from 8 to 9): a request still sitting in the business's inbox finally has a
       customer-side exit. The RPC re-resolves ownership exactly as the reader does, so this
       button can only ever withdraw a row this page was allowed to show. */
    $('walletBody').querySelectorAll('[data-withdraw-request]').forEach(button=>{
      button.onclick=async()=>{
        if(button.disabled)return;
        if(!confirm('Withdraw this booking request? The business will not see it any more.'))return;
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
  renderCustomerShell({active:'messages',backTo:'#/wallet',staffWorkspaces:context.staffWorkspaces,messagesAvailable:true,body:`<header class="customer-page-head"><div><h1>Messages</h1><p class="muted">Customer-safe updates grouped by your separate business programmes.</p></div></header>
    <section class="card wallet-section" id="customerInAppInbox" aria-busy="true" tabindex="-1"><div class="wallet-skeleton"></div></section>`});
  focusCustomerRoute();
  await renderCustomerInAppInbox(null,isCurrent);
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
      <button class="btn" id="customerProfileSave" type="button" style="margin-top:16px">${CUI.icon('check',{size:17})}<span>Save profile</span></button>
    </section><aside class="card"><h2>Date of birth</h2><p style="font-weight:700;margin-top:8px">${esc(profile.birth_date?walletDate(`${profile.birth_date}T00:00:00+08:00`):'Not available')}</p><p class="muted small" style="margin-top:8px">Your date of birth is not editable here and is not shown to businesses.</p></aside></div>`
    :detailsLoadFailedV286
      ?`<section class="card" id="customerProfileDetailsError"><h2>We couldn’t load your details</h2><p class="muted small" style="margin-top:6px">Your name and date of birth did not load just now. Nothing has been changed, and everything below still works.</p><button class="btn" id="customerProfileDetailsRetry" type="button" style="margin-top:16px">${CUI.icon('check',{size:17})}<span>Try again</span></button></section>`
      :'<section class="card"><h2>Profile editing is not available</h2><p class="muted small" style="margin-top:6px">Profile editing isn’t available for this account.</p></section>';
  $('walletBody').innerHTML=`<header class="customer-page-head"><div><h1>Profile</h1><p class="muted">${profile?`Keep your name up to date and manage your ${esc(BRAND.customerLabel)} account.`:`Your ${esc(BRAND.customerLabel)} account details.`}</p></div></header>
    ${personalDetailsHtmlV286}
    <section class="card" id="customerAppearance" style="margin-top:14px"><div class="wallet-section-head"><div><h2>Appearance</h2><p class="muted small">Peekaa looks the same as your businesses do by default. Switch to dark if you prefer it.</p></div></div>
      <div class="customer-theme-choice" role="radiogroup" aria-label="Appearance">${[['light','Light','Beige, like the business app'],['dark','Dark','Easier at night'],['device','Match my device','Follows your phone setting']].map(([value,label,hint])=>`<label class="customer-theme-option" for="customerTheme-${value}"><input type="radio" id="customerTheme-${value}" name="customerTheme" value="${value}" ${customerThemePreferenceV190()===value?'checked':''}><span><b>${esc(label)}</b><span class="muted small" style="display:block">${esc(hint)}</span></span></label>`).join('')}</div>
    </section>
    <section class="card" id="customerExperiencePreferences" style="margin-top:14px"><div class="wallet-section-head"><div><h2>${esc(ct('successSounds'))}</h2><p class="muted small">${esc(ct('soundHelp'))}</p></div><span class="spacer"></span><label class="customer-sound-toggle" for="customerSuccessSound"><input id="customerSuccessSound" type="checkbox" ${customerCelebrationSoundEnabled?'checked':''}><span>${esc(customerCelebrationSoundEnabled?ct('soundOn'):ct('soundOff'))}</span></label></div></section>
    <section class="card" id="customerMarketingPreference" style="margin-top:14px"><h2>Marketing choices</h2><p class="muted small" style="margin-top:5px">Offers and updates from Nestly Technologies Pte. Ltd., the company behind ${esc(BRAND.productName)}, and its partners, by push notification, in-app message, email, SMS, WhatsApp, phone call and other marketing channels. Your name and contact details may be shared with ${esc(BRAND.productName)}’s partners for marketing purposes only. This is separate from messages sent by individual businesses.</p>
      ${marketingPreference?`<label class="row" for="customerProfileMarketing" style="align-items:flex-start;margin-top:14px;color:var(--ink);font-weight:500"><input id="customerProfileMarketing" type="checkbox" ${marketingPreference.opted_in===true?'checked':''} style="width:20px;min-width:20px;min-height:20px;margin-top:1px"> <span>Yes — send me these offers and updates. I can turn this off here, or in <a href="#/customer/communications" style="color:var(--coral);text-decoration:underline">Communications</a>, at any time. ${esc(BRAND.productName)} stops sending straight away. Partners are told to stop within 10 business days. Turning it off does not affect my points, bookings or service messages.</span></label>
      <div id="customerProfileMarketingStatus" role="status" aria-live="polite"></div>
      <button class="btn ghost" id="customerProfileMarketingSave" type="button" style="margin-top:16px">${CUI.icon('check',{size:17})}<span>Save marketing choice</span></button>`
      /* v286: a failed read used to render this sentence ALONE — no checkbox, no save button, and
         nothing to press. Withdrawing marketing consent is the one control here the customer can
         demand at any time, so the read is retryable instead of a dead end. */
      :'<p class="err" role="status" style="margin-top:12px">Your marketing choice could not be loaded. No change has been made.</p><button class="btn ghost" id="customerMarketingRetry" type="button" style="margin-top:14px">Try again</button>'}
    </section>
    <section class="card" id="customerCommunicationsEntry" style="margin-top:14px"><div class="wallet-section-head"><div><h2>Communications</h2><p class="muted small">Choose what you hear about and how — offers from businesses you follow, your rewards and points, and Peekaa updates.</p></div><span class="spacer"></span><a class="btn ghost sm" href="#/customer/communications">${CUI.icon('bell',{size:17})}<span>Open communications</span></a></div></section>
    <section class="card" id="customerConsentHistory" style="margin-top:14px" aria-busy="true"><div class="wallet-section-head"><div><h2>Your consent history</h2><p class="muted small">Every marketing choice you have made, newest first. This is a record only — to change something, open Communications above.</p></div></div><div id="customerConsentHistoryBody" style="margin-top:12px"><p class="muted small">Loading your consent history…</p></div></section>
    <section class="card" id="customerPasswordManage" style="margin-top:14px"><h2>Change password</h2><p class="muted small" style="margin-top:5px">Your password is used for normal sign-in and does not send an OTP.</p>
      <label for="customerProfilePassword">New password</label>${passwordControlHtml('customerProfilePassword',{autocomplete:'new-password',minlength:'12'})}
      <label for="customerProfilePasswordConfirm">Confirm new password</label>${passwordControlHtml('customerProfilePasswordConfirm',{autocomplete:'new-password',minlength:'12'})}
      <div id="customerProfilePasswordStatus" role="status" aria-live="polite"></div>
      <button class="btn" id="customerProfilePasswordSave" type="button" style="margin-top:16px">${CUI.icon('check',{size:17})}<span>Update password</span></button>
    </section>
    <section class="card" id="customerPasskeys" style="margin-top:14px" aria-busy="true"><div class="wallet-section-head"><div><h2>Face ID, Touch ID &amp; passkeys</h2><p class="muted small">Register this device for quicker passwordless sign-in. Your face or fingerprint stays on your device.</p></div><span class="spacer"></span><button class="btn sm" id="customerPasskeyAdd" type="button">${CUI.icon('add',{size:17})}<span>Add passkey</span></button></div><div id="customerPasskeyList"><p class="muted small">Checking registered passkeys…</p></div><p id="customerPasskeyManageStatus" class="muted small" role="status" aria-live="polite" style="margin-top:8px"></p></section>
    ${NestlyNativeBridge.isNative?'':`<section class="card customer-push-setting" id="customerDeviceNotifications" style="margin-top:14px"><div><h2>Device notifications</h2><p class="muted small" data-push-status role="status" aria-live="polite">Checking this device…</p><p class="muted small" style="margin-top:7px">This switch controls whether this device can show notifications at all. Which ones you actually receive is set in <a href="#/customer/communications">Communications</a> — offers, rewards and points, and Peekaa updates each have their own channels there.</p></div><button class="btn ghost" id="customerPushProfileControl" type="button" aria-pressed="false">${CUI.icon('bell',{size:17})}<span data-push-label>Turn on device notifications</span></button></section>`}
    ${accountDeletionCardHtml()}`;
  bindPasswordVisibility($('walletBody'));
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
    passkeyList.innerHTML=passkeys.length?passkeys.map(item=>`<div class="wallet-line"><div><b>${esc(item.friendly_name||'Passkey')}</b><p class="muted small" style="margin-top:3px">Added ${esc(formatPasskeyDate(item.created_at))}${item.last_used_at?` · last used ${esc(formatPasskeyDate(item.last_used_at))}`:''}</p></div><span class="spacer"></span><button class="btn ghost sm" type="button" data-passkey-rename="${esc(item.id)}" data-passkey-name="${esc(item.friendly_name||'Passkey')}" aria-label="Rename ${esc(item.friendly_name||'passkey')}">Rename</button><button class="btn danger sm" type="button" data-passkey-delete="${esc(item.id)}" aria-label="Remove ${esc(item.friendly_name||'passkey')}">Remove</button></div>`).join('')
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
    const {error}=await sb.auth.registerPasskey();
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
  renderCustomerShell({active:'programmes',body:`<div class="card"><h1>${invitationToken?'Accept invitation':'Add a business programme'}</h1><p class="muted small" style="margin-top:6px">${invitationToken?'Confirm this private invitation while signed in to the intended account.':phoneClaimAvailable?'Enter the business link from its QR or invitation. We only connect an exact unclaimed record.':'Use the same confirmed email your business has on file.'}</p>
      <div id="claimPersonas" style="margin-top:14px"><p class="muted small">Checking access…</p></div>
      ${invitationToken?'':`${phoneClaimAvailable?`<fieldset style="border:0;padding:0;margin-top:14px"><legend class="small" style="font-weight:700">How should we find your record?</legend><label class="row" for="claimByPhone" style="color:var(--ink);font-weight:500"><input id="claimByPhone" name="claimMethod" type="radio" value="phone" checked style="width:20px;min-width:20px;min-height:20px"> <span>Use my verified mobile number</span></label><label class="row" for="claimByEmail" style="margin-top:10px;color:var(--ink);font-weight:500"><input id="claimByEmail" name="claimMethod" type="radio" value="email" style="width:20px;min-width:20px;min-height:20px"> <span>Use my confirmed email instead</span></label></fieldset>`:''}<label for="claimSlug">Business link</label><input id="claimSlug" autocomplete="off" placeholder="business-slug or ${esc(BRAND.productName)} link" value="${esc(businessIntent)}">`}
      <button class="btn" id="claimStart" style="margin-top:14px">${invitationToken?'Accept invitation':'Claim'}</button>
      <div id="claimResult"></div></div>`});
  focusCustomerRoute();
  const renderPersonas=async()=>{
    const {data,error}=await sb.rpc('get_my_personas');
    if(!isClaimCurrent())return;
    if(error){
      $('claimPersonas').innerHTML=`<div class="err">Customer access could not be checked. <button class="btn ghost sm" id="claimPersonaRetry" style="margin-left:8px">Retry</button></div>`;
      $('claimPersonaRetry').onclick=renderPersonas;
      return;
    }
    const staff=sortStaffWorkspaces(data?.staff||[]),customer=data?.customer||[];
    const staffLinks=staff.map(workspace=>`<a class="btn ghost sm" href="#/workspace/${encodeURIComponent(workspace.business_slug)}/dashboard">${esc(workspace.business_name||workspace.business_slug)}</a>`).join('');
    $('claimPersonas').innerHTML=staff.length&&customer.length
      ?`<div class="card" style="background:var(--bg)"><b>Choose where to continue</b><div class="row" style="margin-top:10px">${staffLinks}<a class="btn ghost sm" href="#/wallet">${esc(BRAND.customerLabel)}</a></div></div>`
      :customer.length
        ?`<p class="muted small">Wallet links: ${customer.map(x=>`<a style="color:#D06A2E" href="#/wallet/${encodeURIComponent(x.business_slug)}">${esc(x.business_name)}</a>`).join(', ')}</p>`
        :staff.length
          ?`<div><p class="muted small">Staff workspaces:</p><div class="row" style="margin-top:8px">${staffLinks}</div></div>`
          :'<p class="muted small">No wallet links yet.</p>';
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
    const originalLabel=invitationToken?'Accept invitation':'Claim';
    $('claimStart').disabled=true;$('claimStart').textContent='Checking…';
    if(method==='email'||method==='invitation'){
      const identity=await sb.rpc('customer_create_identity',{p_idempotency_key:identityAttemptId});
      if(!isClaimCurrent())return;
      if(identity.error){
        $('claimStart').disabled=false;$('claimStart').textContent=originalLabel;
        $('claimResult').innerHTML='<div class="err">Customer access is unavailable. Please try again later.</div>';return;
      }
    }
    const {data,error}=invitationToken
      ?await sb.rpc('customer_claim_link_invitation',{p_token:invitationToken,p_idempotency_key:claimAttempt.id})
      :method==='phone'
        ?await sb.rpc('customer_claim_link_by_verified_phone',{p_business_slug:slug,p_idempotency_key:claimAttempt.id})
        :await sb.rpc('customer_claim_link_by_email',{p_business_slug:slug,p_idempotency_key:claimAttempt.id});
    if(!isClaimCurrent())return;
    $('claimStart').disabled=false;$('claimStart').textContent=originalLabel;
    if(error){$('claimResult').innerHTML='<div class="err">Customer access is unavailable. Please try again later.</div>';return}
    pendingCustomerInvitationToken='';
    const outcome=data?.outcome||'no_link_created';
    if(!invitationToken&&outcome==='linked'){
      pendingCustomerBusinessSlug='';
      rememberPendingCustomerDestination('');
      nav('#/wallet/'+encodeURIComponent(slug));return;
    }
    $('claimResult').innerHTML=`<div class="card" style="margin-top:16px"><b>${outcome==='linked'?'Linked':'Request received'}</b>
      <p class="muted small" style="margin-top:6px">${outcome==='linked'?'Your wallet is ready.':'If the details match an available customer record, the business link will appear here.'}</p>
      ${outcome==='linked'?'<button class="btn sm" id="goWallet" style="margin-top:10px">Open wallet</button>':''}</div>`;
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
  body.innerHTML=`<section class="card" style="text-align:center;padding:30px 22px" aria-labelledby="customerNotJoinedTitle">
    <div aria-hidden="true">${CUI.icon('loyalty',{size:34})}</div>
    <h2 id="customerNotJoinedTitle" style="margin-top:12px">You haven’t joined ${esc(label)} yet</h2>
    <p class="muted small" style="margin-top:8px">Your Peekaa account is fine — this reward account just isn’t linked to it. Join to see points, rewards and bookings for ${esc(label)}.</p>
    <button class="btn" id="customerNotJoinedJoin" type="button" style="margin-top:18px">${CUI.icon('forward',{size:18})}<span>Join ${esc(label)}</span></button>
    <button class="btn ghost sm" id="customerNotJoinedScan" type="button" style="margin-top:10px">${CUI.icon('scan',{size:17})}<span>${esc(ct('scanBusinessQr'))}</span></button>
    <p class="muted small" style="margin-top:12px"><a href="#/customer/programmes" style="color:var(--coral);text-decoration:underline">Back to My Rewards</a></p>
  </section>`;
  const join=$('customerNotJoinedJoin');
  if(join)join.onclick=()=>{
    pendingCustomerBusinessSlug=normalizeCustomerBusinessIntent(businessSlug);
    nav('#/claim?business='+encodeURIComponent(String(businessSlug||'')));
  };
  const scan=$('customerNotJoinedScan');
  if(scan)scan.onclick=openCustomerJoinScanner;
}
function renderCustomerWalletRetry(message,businessSlug,retry=()=>renderCustomerWallet(businessSlug),error=null){
  globalThis.document?.documentElement?.setAttribute('lang','en');
  const body=$('walletBody');if(!body)return;
  const expired=walletSessionExpired(error);
  body.innerHTML=`<div class="card" style="text-align:center"><h2>Could not load ${esc(BRAND.customerLabel)}</h2><p class="muted small" style="margin-top:8px">${esc(expired?'Your sign-in expired. Sign in again.':message)}</p><button class="btn sm" id="walletRetry" style="margin-top:14px">${expired?'Sign in':'Retry'}</button></div>`;
  $('walletRetry').onclick=expired?(()=>customerSessionExpiredSignIn()):retry;
}

function walletSectionShell(id,title,description=''){
  return `<section class="card wallet-section" id="${id}" data-section-title="${esc(title)}" aria-busy="true"><div class="wallet-section-head"><div><h2>${esc(title)}</h2>${description?`<p class="muted small">${esc(description)}</p>`:''}</div></div><div class="wallet-skeleton"></div></section>`;
}

function walletSectionError(id,message,retry,error=null){
  const host=$(id);if(!host)return;
  host.setAttribute('aria-busy','false');
  const title=host.dataset.sectionTitle||host.querySelector('h2')?.textContent?.trim()||'This section';
  if(walletSessionExpired(error)){
    host.innerHTML=`<div class="wallet-section-head"><div><h2>${esc(title)} didn’t load</h2><p class="muted small">Your sign-in expired. Sign in again.</p></div><span class="spacer"></span><button class="btn ghost sm" id="${id}Retry">Sign in</button></div>`;
    $(`${id}Retry`).onclick=()=>customerSessionExpiredSignIn();
    return;
  }
  host.innerHTML=`<div class="wallet-section-head"><div><h2>${esc(title)} didn’t load</h2><p class="muted small">${esc(message)}</p></div><span class="spacer"></span><button class="btn ghost sm" id="${id}Retry">Retry</button></div>`;
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
      ${customerFeatures.customer_actions&&appointmentChangesEnabled&&a.status==='booked'?`<button class="btn ghost sm walletChange" data-id="${esc(a.appointment_id)}">Change</button>`:a.status==='completed'?`<button class="btn ghost sm" type="button" data-repeat-booking data-business-slug="${esc(businessSlug)}" data-appointment-id="${esc(a.appointment_id)}">Book again</button>`:''}</div>`).join('')}</div>
    ${state.nextCursor?'<button class="btn ghost sm" id="walletAppointmentsMore" style="margin-top:12px">Load more</button>':''}`;
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
  if(action.reason==='reward_progress')return `${Number(reward.remaining_units||0)} ${unit} to ${reward.name||'your next reward'}`;
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
  const heroColor=contrastSafeBrandColor(/^#[0-9a-f]{6}$/i.test(String(brand.hero_color||''))?brand.hero_color
    :/^#[0-9a-f]{6}$/i.test(String(business.brand_color||''))?business.brand_color:'#28212f');
  const unit=String(programme.unit||loyalty.unit||'points').toLowerCase()==='stamps'?'stamps':'points';
  return {
    locale:normalizeCustomerLocale(payload?.locale||customerLocale),
    logoUrl:customerMediaUrlV95(brand.logo_url),
    heroImageUrl:customerMediaUrlV95(brand.hero_image_url),
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
function customerProgrammeLogoV95(presentation,businessName){
  return presentation.logoUrl
    ?`<img src="${esc(presentation.logoUrl)}" alt="${esc(businessName||presentation.name)} logo" loading="eager">`
    :esc(String(businessName||presentation.name||'N').trim().charAt(0).toUpperCase()||'N');
}
function customerProgrammeSwitcherMarkup(cards=[],activeSlug=''){
  if(cards.length<2)return '';
  return `<div class="customer-programme-switcher" role="navigation" aria-label="${esc(ct('chooseProgramme'))}">${cards.map(card=>{
    const business=card?.business||{};
    return `<a href="#/wallet/${encodeURIComponent(business.slug||'')}" aria-current="${business.slug===activeSlug?'true':'false'}">${esc(business.name||ct('localBusiness'))}</a>`;
  }).join('')}</div>`;
}
const CUSTOMER_SEEN_OFFERS_KEY_V167='peekaa.customer.offers.seen.v1';
let customerOfferFocusV167=null;
function customerSeenOfferVersionsV167(){
  try{
    const parsed=JSON.parse(localStorage.getItem(CUSTOMER_SEEN_OFFERS_KEY_V167)||'[]');
    return new Set(Array.isArray(parsed)?parsed.filter(value=>typeof value==='string').slice(-200):[]);
  }catch{return new Set()}
}
function rememberCustomerOfferV167(versionId){
  if(!versionId)return;
  const seen=customerSeenOfferVersionsV167();seen.add(String(versionId));
  try{localStorage.setItem(CUSTOMER_SEEN_OFFERS_KEY_V167,JSON.stringify([...seen].slice(-200)))}catch{}
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
  const initial=(String(item?.name||'Offer').trim()[0]||'O').toUpperCase();
  const businessInitial=(String(business.name||'B').trim()[0]||'B').toUpperCase();
  return `<a class="customer-home-offer${image?'':' customer-home-offer--no-media'}" href="#/wallet/${encodeURIComponent(business.slug||'')}" data-home-offer data-offer-id="${esc(item?.id||'')}" data-offer-version="${esc(versionId)}">
    ${image?`<div class="customer-home-offer-media"><img src="${esc(image)}" alt="${esc(item?.image_alt||item?.name||'Offer')}" loading="lazy"></div>`:`<div class="customer-home-offer-media customer-home-offer-media--fallback" aria-hidden="true"><span>${esc(initial)}</span></div>`}
    <div class="customer-home-offer-copy"><div class="customer-home-offer-meta">${isNew?'<span class="pill customer-offer-new">New</span>':''}${endsSoon?'<span class="pill customer-offer-urgent">Ends soon</span>':''}</div><h3>${esc(item?.name||'Offer')}</h3>
    <p class="customer-home-offer-business">${logo
      ?`<img class="customer-home-offer-logo" src="${esc(logo)}" alt="" loading="lazy" width="24" height="24">`
      :`<span class="customer-home-offer-logo customer-home-offer-logo--fallback" aria-hidden="true">${esc(businessInitial)}</span>`}<span class="muted small">${esc(business.name||'Your business')}${category?` · ${esc(category)}`:''}</span></p>
    ${countdown?`<p class="customer-home-offer-countdown">${esc(countdown)}</p>`:validity?`<p class="muted small" style="margin-top:5px">${esc(validity)}</p>`:''}</div>
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
      <h2 id="customerExpiringTitle">${CUI.icon('retention',{size:18})}<span>Expiring rewards</span></h2>
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
  const items=interleaveCustomerOffersV173(state.items);
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
  return `<section class="customer-home-offers" aria-labelledby="customerHomeOffersTitle"><div class="customer-home-offers-head"><h2 id="customerHomeOffersTitle" class="customer-home-offers-title"><span class="customer-home-offers-badge" aria-hidden="true">${CUI.icon('loyalty',{size:18})}</span><span>Limited offers</span></h2></div>${body}</section>`;
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
function showCustomerBusinessDetailV178(business={},{inheritHistoryId=0}={}){
  const name=String(business?.name||'').trim()||'Your business',slug=encodeURIComponent(business?.slug||''),
    industry=String(business?.industry||'').trim();
  const overlay=document.createElement('div');
  overlay.className='modal customer-surface customer-business-detail-modal';overlay.setAttribute('role','dialog');
  overlay.setAttribute('aria-modal','true');overlay.setAttribute('aria-labelledby','customerBusinessDetailTitle');
  overlay.innerHTML=`<section class="modal-card customer-offer-detail customer-business-detail">
    <div class="row"><p class="customer-quest-kicker">Company details</p><span class="spacer"></span><button class="btn ghost sm" id="customerBusinessDetailClose" type="button" aria-label="Close company details">${CUI.icon('close',{size:18})}</button></div>
    <div class="customer-business-detail-head">${customerCompanyIdentityMarkupV178(business)}<div><h2 id="customerBusinessDetailTitle">${esc(name)}</h2>${industry?`<p class="muted small" style="margin-top:2px">${esc(industry)}</p>`:''}</div></div>
    <div class="customer-offer-detail-meta" data-business-contact><p class="muted small">Loading contact details…</p></div>
    <h3 class="customer-business-detail-subhead">Current offers</h3>
    <div data-business-offers><p class="muted small">Loading offers…</p></div>
    <div class="row" style="margin-top:16px"><a class="btn" href="#/wallet/${slug}" data-business-detail-nav>${esc(ct('openProgramme',{business:name}))}</a></div>
  </section>`;
  document.body.appendChild(overlay);
  const deactivate=CUI.activateDialog(overlay,{onClose:()=>deactivate({restoreFocus:true}),initialFocus:'#customerBusinessDetailClose',inheritHistoryId});
  overlay.querySelector('#customerBusinessDetailClose').onclick=()=>deactivate({restoreFocus:true});
  wireCustomerSheetNavV183(overlay,deactivate);
  const host=selector=>overlay.isConnected?overlay.querySelector(selector):null;
  if(!business?.id){
    const contact=host('[data-business-contact]');if(contact)contact.innerHTML='<p class="muted small">Contact details unavailable.</p>';
    const offers=host('[data-business-offers]');if(offers)offers.innerHTML='<p class="muted small">Current offers are unavailable.</p>';
    return;
  }
  Promise.resolve(customerRpc('customer_get_offer_business_contact_v173',{p_business:business.id}))
    .then(({data,error})=>{
      const contact=host('[data-business-contact]');if(!contact)return;
      if(error){contact.innerHTML='<p class="muted small">Contact details unavailable.</p>';return}
      const branch=data?.branch||{};
      const lines=[
        branch.address?`<p class="muted small">${CUI.icon('bookings',{size:14})} ${esc(branch.address)}</p>`:'',
        branch.phone?`<p class="muted small"><a href="tel:${esc(String(branch.phone).replace(/[^+0-9]/g,''))}">${esc(branch.phone)}</a></p>`:'',
        branch.email?`<p class="muted small"><a href="mailto:${esc(branch.email)}">${esc(branch.email)}</a></p>`:''
      ].filter(Boolean).join('');
      contact.innerHTML=lines||'<p class="muted small">Contact details unavailable.</p>';
    }).catch(()=>{
      const contact=host('[data-business-contact]');
      if(contact)contact.innerHTML='<p class="muted small">Contact details unavailable.</p>';
    });
  Promise.resolve(customerRpc('customer_get_promotions_v155',{p_business:business.id,p_branch:null,p_locale:'en'}))
    .then(({data,error})=>{
      const offersHost=host('[data-business-offers]');if(!offersHost)return;
      if(error){offersHost.innerHTML='<p class="muted small">Current offers couldn’t load.</p>';return}
      const items=(Array.isArray(data?.items)?data.items:Array.isArray(data)?data:[]).filter(Boolean);
      if(!items.length){offersHost.innerHTML='<p class="muted small">No current offers from this business.</p>';return}
      offersHost.innerHTML=`<div class="customer-business-offer-list">${items.map((offer,index)=>{
        const validity=customerPromotionValidityV104(offer);
        return `<button class="customer-business-offer" type="button" data-business-offer="${index}"><span class="customer-business-offer-copy"><b>${esc(offer?.name||'Offer')}</b>${validity?`<span class="muted small">${esc(validity)}</span>`:''}</span><span class="spacer"></span><span class="customer-company-row-chevron" aria-hidden="true">›</span></button>`;
      }).join('')}</div>`;
      offersHost.querySelectorAll('[data-business-offer]').forEach(button=>button.onclick=()=>{
        const offer=items[Number(button.dataset.businessOffer)];
        if(!offer)return;
        const handOff=CUI.currentDialogHistoryId?.()||0;
        deactivate({restoreFocus:false,handOffHistory:handOff>0});
        showCustomerOfferDetailV173({...offer,business:{...business,...(offer.business||{})}},{inheritHistoryId:handOff});
      });
    }).catch(()=>{
      const offersHost=host('[data-business-offers]');
      if(offersHost)offersHost.innerHTML='<p class="muted small">Current offers couldn’t load.</p>';
    });
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
    initial=(String(item?.name||'Offer').trim()[0]||'O').toUpperCase(),
    ctaLabel=String(cta.label||'').trim();
  const overlay=document.createElement('div');
  overlay.className='modal customer-surface customer-offer-detail-modal';overlay.setAttribute('role','dialog');
  overlay.setAttribute('aria-modal','true');overlay.setAttribute('aria-labelledby','customerOfferDetailTitle');
  overlay.innerHTML=`<section class="modal-card customer-offer-detail">
    <div class="row"><p class="customer-quest-kicker">Limited-time offer · ${esc(business.name||'Your business')}</p><span class="spacer"></span><button class="btn ghost sm" id="customerOfferDetailClose" type="button" aria-label="Close offer details">${CUI.icon('close',{size:18})}</button></div>
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
  if(companyButton)companyButton.onclick=()=>{
    const handOff=CUI.currentDialogHistoryId?.()||0;
    deactivate({restoreFocus:false,handOffHistory:handOff>0});
    showCustomerBusinessDetailV178(business,{inheritHistoryId:handOff});
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
          branch.address?`<p class="muted small">${CUI.icon('bookings',{size:14})} ${esc(branch.address)}</p>`:'',
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
function customerRewardProgressMarkupV167(card){
  const reward=card?.next_eligible_reward||null,loyalty=card?.loyalty||{};
  if(!reward)return '';
  const balance=Math.max(0,Number(loyalty.balance)||0),cost=Math.max(0,Number(reward.cost_units)||0),
    unit=String(loyalty.unit||'points'),available=reward.available_now===true||cost===0,
    progress=cost>0?Math.min(100,Math.max(0,Math.round((balance/cost)*100))):100;
  return `<div class="customer-reward-progress-copy"><p class="muted small">${available?`${esc(reward.name||'Reward')} is ready to redeem.`:`${esc(customerPointTotalV103(reward.remaining_units||0))} ${esc(unit)} to ${esc(reward.name||'your next reward')}.`}</p><div class="customer-reward-progress" role="progressbar" aria-label="Progress to ${esc(reward.name||'next reward')}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${progress}" style="--reward-progress:${progress}%"><span></span></div></div>`;
}
function customerTierHasProgressV103(tier={}){
  const named=[tier.current,tier.label,tier.next].some(value=>String(value||'').trim().length>0);
  const progress=Number(tier.progress_percent);
  return named||(Number.isFinite(progress)&&progress>0);
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
function customerShareSheetMarkupV264({text,url,business={}}){
  const message=customerShareMessageV267(text,business);
  const channels=CUSTOMER_SHARE_CHANNELS_V264
    .map(channel=>`<a class="customer-share-channel" href="${esc(channel.href({text:message,url}))}" target="_blank" rel="noopener noreferrer" data-share-channel="${esc(channel.key)}">${CUI.icon(channel.icon,{size:18})}<span>${esc(channel.label)}</span></a>`)
    .join('');
  return `<section class="modal-card customer-share-sheet">
    <div class="row"><h2 id="customerShareTitle">Share this offer</h2><span class="spacer"></span>
      <button class="btn ghost sm" id="customerShareClose" type="button" aria-label="Close">${CUI.icon('close',{size:18})}</button></div>
    ${customerShareLockupV267(business)}
    <p class="muted small">${esc(text)}</p>
    <div class="customer-share-channels">${channels}</div>
    <button class="btn ghost sm customer-share-copy" id="customerShareCopy" type="button" data-share-channel="copy">${CUI.icon('copy',{size:17})}<span>Copy link</span></button>
    <p class="muted small customer-share-note">Instagram, TikTok and WeChat can be reached from your phone's own share button.</p>
  </section>`;
}
function showCustomerShareSheetV264({text,url,business={},onChannel=()=>{}}){
  const overlay=document.createElement('div');
  overlay.className='modal customer-surface customer-share-modal';
  overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');
  overlay.setAttribute('aria-labelledby','customerShareTitle');
  overlay.innerHTML=customerShareSheetMarkupV264({text,url,business});
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
function customerFeaturePriceLabelV156(item={}){
  const cents=Number(item.price_cents??item.unit_price_cents??item.default_price_cents??item.amount_cents??0);
  const currency=String(item.currency||item.currency_code||'SGD').toUpperCase();
  return Number.isFinite(cents)&&cents>0?`${currency} ${(cents/100).toFixed(2)}`:'';
}
function customerFeatureDurationLabelV156(item={}){
  const minutes=Number(item.duration_minutes??item.minutes??0);
  return Number.isFinite(minutes)&&minutes>0?`${minutes} min`:'';
}
function customerFeatureTypeLabelV156(item={}){
  const type=String(item.entity_type||item.kind||item.type||'').toLowerCase();
  if(type.includes('product'))return 'Product';
  if(type.includes('service'))return 'Service';
  return 'Available';
}
function customerFeatureCardMarkupV156(item={}){
  const image=customerMediaUrlV95(item?.image_url);
  const price=customerFeaturePriceLabelV156(item);
  const duration=customerFeatureDurationLabelV156(item);
  const label=customerFeatureTypeLabelV156(item);
  const description=String(item.description||item.tagline||'').trim();
  return `<article class="customer-reward-card customer-feature-card">
    ${image?`<img class="customer-feature-image" src="${esc(image)}" alt="" loading="lazy">`:''}
    <b>${esc(item.name||ct('featured'))}</b>
    <div class="customer-feature-meta"><span class="pill">${esc(label)}</span>${price?`<span class="pill">${esc(price)}</span>`:''}${duration?`<span class="pill">${esc(duration)}</span>`:''}</div>
    ${description?`<p class="muted small" style="margin-top:7px">${esc(description)}</p>`:''}
  </article>`;
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
function customerPointsExplainerMarkupV167(business={}){
  const key=`peekaa.customer.points-explainer.v1.${String(business.id||business.slug||'programme')}`;
  try{if(localStorage.getItem(key)==='dismissed')return ''}catch{}
  return `<aside class="card customer-points-explainer" data-points-explainer data-points-explainer-key="${esc(key)}" role="note"><p><b>How rewards work at ${esc(business.name||'this business')}</b><br><span class="muted small">Collect points here and use them for available rewards.</span></p><button class="btn ghost sm" type="button" data-points-explainer-dismiss aria-label="Dismiss points explanation">Got it</button></aside>`;
}
function customerProgrammeOffersMarkupV167({items=[],status='ready',business={},bookingEnabled=false}={}){
  let body='';
  if(status==='error')body='<div class="card customer-home-offers-state"><p class="muted small">Offers couldn’t load.</p><button class="btn ghost sm" type="button" data-programme-offers-retry>Try again</button></div>';
  else if(items.length)body=`<div class="customer-promotions-grid">${items.map(item=>customerPromotionCardV104(item,business,bookingEnabled)).join('')}</div>`;
  else body='<div class="card customer-home-offers-state"><p class="muted small">No offers right now. New offers from this business appear here first.</p></div>';
  return `<section class="customer-promotions-section" aria-labelledby="latestOffersTitle"><div class="customer-promotions-head"><div><p class="customer-quest-kicker">From ${esc(business.name||ct('localBusiness'))}</p><h2 id="latestOffersTitle">Latest offers</h2></div></div>${body}</section>`;
}
/* V174 customer tier card. One compact card, CHAGEE-style: where I am, how close the next
   tier is (exact remaining in the business's own basis — visits, spend or points), what the
   next tier unlocks (two-item teaser), then my current benefits. Renders nothing when the
   business has no tiers, and never shows raw percentages without the human sentence. */
/* v194 (owner annotations, 2026-08-07): the programme card was one long column — a tier block
   with two lines of prose above a permanently expanded ladder, and the balance stranded in the
   header. It is now two tabs, Tier and Reward points, which is what the owner sketched. The tier
   panel drops "Gold unlocks…" and "Your benefits now" (both struck out as "too many wordings"),
   names the rung plainly — "You're now at Basic" — marks every rung ON the progress bar, and
   folds the full ladder behind a disclosure that opens on tap. */
/* v195 (owner drew a star, a crown and a gem onto the rungs): the marker is positional, not a
   claim about the tier's name — first rung star, top rung gem, everything between a crown — so a
   business that calls its tiers Bronze/Silver/Gold gets the same read as one using Basic/Diamond. */
function customerTierRungIconV195(index,total){
  if(index<=0)return 'star';
  return index>=total-1?'diamond':'crown';
}
function customerTierMilestonesMarkupV194(tier={}){
  const rungs=(Array.isArray(tier.tiers)?tier.tiers:[]).filter(rung=>String(rung?.label||'').trim());
  if(rungs.length<2)return '';
  const top=Math.max(...rungs.map(rung=>Math.max(0,Number(rung.threshold)||0)));
  if(!(top>0))return '';
  return `<div class="customer-tier-milestones" aria-hidden="true">${rungs.map((rung,index)=>{
    const at=Math.max(0,Math.min(100,(Math.max(0,Number(rung.threshold)||0)/top)*100));
    return `<span class="customer-tier-milestone${rung.current===true?' is-current':''}${rung.achieved===true?' is-achieved':''}" style="left:${at.toFixed(2)}%"><i>${CUI.icon(customerTierRungIconV195(index,rungs.length),{size:14})}</i><b>${esc(rung.label)}</b></span>`;
  }).join('')}</div>`;
}
function customerTierPanelMarkupV194(tier={}){
  const current=tier.current,next=tier.next;
  /* V230 (owner: "only 1 can be live at any go ... reflected in the customer portal"). When the
     firm redeems points for rewards, the tier ladder is not the story — showing it alongside
     "spend your points" was exactly the double narrative the owner ruled out. The reader tells
     us the firm's choice; an unchosen firm keeps today's behaviour. */
  if(String(tier.points_mode||'')==='redeem'){
    return '';
  }
  if(tier.unavailable==='not_running'){
    return `<p class="muted small">This business is not running a tier programme at the moment. Your points and rewards are unaffected.</p>`;
  }
  if(tier.unavailable==='error'){
    return `<p class="muted small">Your tier could not be checked just now. Nothing has changed — reload to try again.</p>`;
  }
  if(!current&&!next)return '<p class="muted small">This business has not set up tiers yet.</p>';
  const basis=String(tier.basis||'visits');
  const metric=Number(tier.metric||0);
  const progress=Math.max(0,Math.min(100,Number(tier.progress_percent||0)));
  const remainingText=(()=>{
    if(!next)return '';
    const remaining=Math.max(0,Number(next.threshold||0)-metric);
    if(basis==='spend')return `Spend SGD ${remaining.toLocaleString('en-SG',{maximumFractionDigits:0})} more to reach ${next.label}`;
    if(basis==='points_earned')return `Earn ${Math.ceil(remaining).toLocaleString('en-SG')} more points to reach ${next.label}`;
    const visits=Math.ceil(remaining);
    return `${visits.toLocaleString('en-SG')} more visit${visits===1?'':'s'} to reach ${next.label}`;
  })();
  const currentRequirement=current&&!next?customerTierRequirementTextV189(current.threshold,basis):'';
  /* V240: when a firm runs both, the customer holds two independent things — a tier they climb
     and points they spend. Saying so once here stops "will redeeming cost me my tier?".
     V258: the sentence now reads the firm's actual basis. 'points_earned' counts LIFETIME
     points earned, which redemption never reduces, so the reassurance is still true there. */
  const bothNoteV258=String(tier.points_mode||'')==='both'
    ?`<p class="muted small" style="margin-top:6px">${basis==='points_earned'?'Points you earn move you up — spending them never lowers your tier.':basis==='spend'?'What you spend moves you up. Points stay yours to spend.':'Visits move you up. Points stay yours to spend.'}</p>`:'';
  return `<p class="customer-tier-now">You're now at <b>${esc(current?.label||'Getting started')}</b>${next?'':current?' <span class="pill ok">Top tier</span>':''}</p>${bothNoteV258}
    ${next?`<div class="customer-tier-bar"><div class="customer-tier-bar-track"><span style="width:${progress}%"></span></div>${customerTierMilestonesMarkupV194(tier)}</div>
    <p class="muted small customer-tier-remaining">${esc(remainingText)}</p>`
      :currentRequirement?`<p class="muted small customer-tier-remaining">${esc(currentRequirement)} · you are at the highest tier.</p>`:''}
    ${customerTierLadderMarkupV186(tier)}`;
}
/* v186 (owner: "i want to see different tiers and its benefits… mask other tiers, still can see
   the benefits but very obvious that is not their tier"). A ladder you cannot see is not a
   ladder — naming what the next rung unlocks is the entire reason anyone climbs. Every tier is
   listed with its own benefits; the one the SERVER placed the customer on is in full colour, the
   rest are desaturated and dimmed but fully readable, and each carries a word for its state so
   the meaning survives greyscale, colour blindness and a screen reader.
   Renders nothing for a single-tier programme, where a "ladder" would be a lie. */
function customerTierLadderMarkupV186(tier={}){
  const rungs=(Array.isArray(tier.tiers)?tier.tiers:[]).filter(rung=>String(rung?.label||'').trim());
  if(rungs.length<2)return '';
  const basis=String(tier.basis||'visits');
  const metric=Number(tier.metric||0);
  const requirement=threshold=>customerTierRequirementTextV189(threshold,basis);
  return `<details class="customer-tier-ladder">
    <summary><span>All tiers and what they unlock</span><span class="muted small">${rungs.length} tiers</span></summary>
    <ol class="customer-tier-rungs" aria-label="Every tier and what it unlocks">${rungs.map(rung=>{
      const isCurrent=rung.current===true;
      const achieved=rung.achieved===true&&!isCurrent;
      const state=isCurrent?'Your tier':achieved?'Reached':'Not yet yours';
      const benefits=(Array.isArray(rung.benefits)?rung.benefits:[]).filter(value=>String(value||'').trim());
      const remaining=Math.max(0,Number(rung.threshold||0)-metric);
      return `<li class="customer-tier-rung${isCurrent?' is-current':''}${achieved?' is-achieved':''}"${isCurrent?' aria-current="true"':''}>
        <div class="row" style="align-items:baseline;gap:8px">
          <b>${esc(rung.label)}</b>
          <span class="pill ${isCurrent?'ok':'off'}">${esc(state)}</span>
        </div>
        <p class="muted small" style="margin-top:3px">${esc(requirement(rung.threshold))}${!isCurrent&&!achieved&&remaining>0?` · ${esc(customerTierRemainingTextV186(remaining,basis))}`:''}</p>
        ${benefits.length
          ?`<ul class="rec-why" style="margin-top:6px">${benefits.map(benefit=>`<li>${esc(benefit)}</li>`).join('')}</ul>`
          :'<p class="muted small" style="margin-top:6px">Benefits not published yet.</p>'}
      </li>`;
    }).join('')}</ol>
  </details>`;
}
/* What a rung costs, in the business's own basis. Shared by the tier card header and the ladder
   so the two can never word the same threshold differently. */
function customerTierRequirementTextV189(threshold,basis){
  const value=Math.max(0,Number(threshold)||0);
  if(!value)return 'From your first visit';
  if(basis==='spend')return `From SGD ${value.toLocaleString('en-SG',{maximumFractionDigits:0})} spent`;
  if(basis==='points_earned')return `From ${value.toLocaleString('en-SG')} points earned`;
  return `From ${value.toLocaleString('en-SG')} visit${value===1?'':'s'}`;
}
function customerTierRemainingTextV186(remaining,basis){
  if(basis==='spend')return `SGD ${Number(remaining).toLocaleString('en-SG',{maximumFractionDigits:0})} to go`;
  if(basis==='points_earned')return `${Math.ceil(remaining).toLocaleString('en-SG')} points to go`;
  const visits=Math.ceil(remaining);
  return `${visits.toLocaleString('en-SG')} visit${visits===1?'':'s'} to go`;
}
/* v194: Tier and Reward points as two tabs, the shape the owner drew over the old stacked block.
   The balance moves in here from the header, where it sat beside a name it had nothing to do with. */
/* v230 (owner, looking at Cubbly: "instead of showing different points to redeem rewards - it
   should show the relevant selected model. in this case selected tier - it should reflect the
   different tiers and its benefits"): v229 makes a firm choose ONE use for points, and refuses
   redemption server-side when that choice is tiers. Cubbly had chosen tiers, and the customer was
   still being shown a point-priced catalogue with "Show QR at counter" buttons the server would
   reject. The panel is now built from the choice:
     tiers  — one panel: where you stand, what your tier gives you, and every tier above it.
     redeem — one panel: your balance and what it buys. No tier ladder for a firm not running one.
     unset  — both, as before, because nothing has been put away yet.
   The capability comes from the server (customer_portal_capabilities), so the surface and the
   redemption gate can never disagree about which one this firm runs. */
function customerProgrammeModeV230({points_mode=null,tiers=false,rewards=false}={}){
  if(points_mode==='tiers')return 'tiers';
  if(points_mode==='redeem')return 'redeem';
  return tiers&&rewards?'both':tiers?'tiers':'redeem';
}
function customerProgrammePointsPanelV230({loyalty={},presentation={},reward=null,rewardsHost=false}){
  const unitLabel=ct(presentation.unit);
  /* V289 (audit A3, G4). Both wallet readers return loyalty.enabled=false with EVERY number
     zeroed when the firm has the module off or its programme inactive — the server cannot
     disclose a balance for a programme that is not running. This panel printed that zero as a
     bare "0 points", which reads as "you have nothing", when what is true is "nothing is being
     counted right now, and what you already hold is kept". The tier card has said the equivalent
     since v189 (`unavailable==='not_running'`); this is the same sentence for points. Only an
     EXPLICIT false is treated as paused: an older payload with no flag keeps today's behaviour. */
  if(loyalty.enabled===false){
    return `<p class="customer-programme-paused" style="font-size:clamp(1.3rem,5vw,1.7rem);line-height:1.15;letter-spacing:-.02em"><b>Programme paused</b></p>
      <p class="muted small" style="margin-top:6px">This business isn’t running its rewards programme at the moment, so nothing is being counted. Anything you already earned is kept — it reappears here when the programme restarts.</p>`;
  }
  const balance=customerPointTotalV103(loyalty.balance??presentation.balance??0);
  const progress=customerRewardProgressMarkupV167({loyalty,next_eligible_reward:reward});
  return `<p class="customer-programme-balance"><b>${esc(balance)}</b> <span class="muted">${esc(unitLabel)}</span></p>
    ${progress||`<p class="muted small" style="margin-top:6px">Rewards from this business appear below as you earn.</p>`}
    ${rewardsHost?'<div id="walletRewards" class="customer-programme-rewards" data-section-title="Rewards" aria-busy="true"><p class="muted small">Loading rewards…</p></div>':''}`;
}
/* In tiers mode the balance is not a wallet — it is the distance travelled — so it is stated as
   what it counts toward rather than as something to spend. */
function customerProgrammeTierPanelV230({tier={},loyalty={},presentation={}}){
  const unitLabel=ct(presentation.unit);
  const balance=customerPointTotalV103(loyalty.balance??presentation.balance??0);
  const basis=String(tier.basis||'visits');
  const counted=basis==='points_earned'
    ?`<p class="customer-programme-balance"><b>${esc(balance)}</b> <span class="muted">${esc(unitLabel)} earned</span></p>
       <p class="muted small" style="margin-top:6px">Your ${esc(unitLabel)} count toward membership here — they are not spent.</p>`
    :'';
  return `${counted}${customerTierPanelMarkupV194(tier)}`;
}
function customerProgrammeSummaryTabsV194({tier={},loyalty={},presentation={},reward=null,rewardsHost=false,capabilities={}}){
  const mode=customerProgrammeModeV230(capabilities);
  if(mode==='tiers'){
    return `<section class="card customer-programme-tabs customer-programme-single" aria-label="Your tier">
      <h2 class="customer-programme-single-head">${CUI.icon('star',{size:17})}<span>Tier</span></h2>
      ${customerProgrammeTierPanelV230({tier,loyalty,presentation})}
    </section>`;
  }
  if(mode==='redeem'){
    return `<section class="card customer-programme-tabs customer-programme-single" aria-label="Reward points">
      <h2 class="customer-programme-single-head">${CUI.icon('redeem',{size:17})}<span>Reward points</span></h2>
      ${customerProgrammePointsPanelV230({loyalty,presentation,reward,rewardsHost})}
    </section>`;
  }
  return `<section class="card customer-programme-tabs" aria-label="Tier and reward points">
    <div class="customer-programme-tablist" role="tablist" aria-label="Tier and reward points">
      <button type="button" role="tab" id="customerProgrammeTab-tier" class="customer-programme-tab" data-programme-tab="tier" aria-selected="true" aria-controls="customerProgrammePanel" tabindex="0">${CUI.icon('star',{size:17})}<span>Tier</span></button>
      <button type="button" role="tab" id="customerProgrammeTab-points" class="customer-programme-tab" data-programme-tab="points" aria-selected="false" aria-controls="customerProgrammePanel" tabindex="-1">${CUI.icon('redeem',{size:17})}<span>Reward points</span></button>
    </div>
    <div id="customerProgrammePanel" role="tabpanel" tabindex="0" aria-labelledby="customerProgrammeTab-tier">
      <div data-programme-panel="tier">${customerTierPanelMarkupV194(tier)}</div>
      <div data-programme-panel="points" hidden>
        ${customerProgrammePointsPanelV230({loyalty,presentation,reward,rewardsHost})}
      </div>
    </div>
  </section>`;
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
function customerMerchantExperienceMarkupV95({presentation,business,actionableCard,programmeCards,bookingEnabled,offersStatus='ready',rewardsHost=false,programmeCapabilities={}}){
  const loyalty=actionableCard?.loyalty||{},reward=actionableCard?.next_eligible_reward||null;
  const tier=presentation.tier||{};
  const hasTier=customerTierHasProgressV103(tier);
  const currentTierLabel=String(tier.current?.label||tier.current||tier.label||'').trim();
  const currentTierBenefits=Array.isArray(tier.current?.benefits)
    ?tier.current.benefits.filter(value=>String(value||'').trim()).map(value=>String(value).trim()):[];
  const unitLabel=ct(presentation.unit);
  const cardImage=item=>customerMediaUrlV95(item?.image_url);
  const offers=(Array.isArray(presentation.offers)?presentation.offers:[]).slice(0,6);
  /* v194 (owner: "show company details, phone number, address" beside the business name): the
     header is now the way in to the company sheet, and the booking action moved up here — "make
     it smaller and put upstair" — out of the full-width card that sat below the offers. */
  return `${customerProgrammeSwitcherMarkup(programmeCards,business.slug)}
    <header class="customer-programme-compact-head" style="--merchant-accent:${esc(contrastSafeBrandColor(presentation.heroColor))}">
      <button class="customer-programme-identity" type="button" data-company-detail aria-label="Company details for ${esc(business.name||presentation.name)}">
        <span class="customer-programme-logo">${customerProgrammeLogoV95(presentation,business.name)}</span>
        <span class="customer-programme-compact-copy"><b>${esc(business.name||presentation.name)}</b>
          <span class="muted small customer-programme-identity-hint">${hasTier&&currentTierLabel?`${esc(currentTierLabel)} · `:''}<span class="customer-programme-identity-hint-long">Address, phone and offers ›</span><span class="customer-programme-identity-hint-short">Details ›</span></span></span>
      </button>
      ${bookingEnabled?`<a class="btn sm customer-programme-book" href="#/b/${encodeURIComponent(business.slug||'')}" data-repeat-booking data-business-slug="${esc(business.slug||'')}">${CUI.icon('bookings',{size:16})}<span>${esc(ct('bookNow'))}</span></a>`:''}
    </header>
    ${customerPointsExplainerMarkupV167(business)}
    ${customerProgrammeSummaryTabsV194({tier,loyalty,presentation,reward,rewardsHost,capabilities:programmeCapabilities})}
    ${customerProgrammeOffersMarkupV167({items:offers,status:offersStatus,business,bookingEnabled})}
    ${presentation.products.length||presentation.services.length?`<div class="customer-section-title"><h2>${esc(ct('featured'))}</h2></div><div class="customer-rewards-grid">${[...presentation.products.map(item=>({...item,entity_type:item.entity_type||'product'})),...presentation.services.map(item=>({...item,entity_type:item.entity_type||'service'}))].map(customerFeatureCardMarkupV156).join('')}</div>`:`<div class="customer-section-title"><h2>${esc(ct('featured'))}</h2></div><section class="card customer-feature-card"><p class="muted small">Featured services and products will appear here after this business publishes them.</p></section>`}
    ${presentation.benefits.length?`<div class="customer-section-title"><h2>${esc(ct('benefits'))}</h2></div><div class="customer-perks-grid">${presentation.benefits.map(item=>`<article class="customer-perk-card">${cardImage(item)?`<img src="${esc(cardImage(item))}" alt="" loading="lazy">`:''}<b>${esc(item.name||ct('benefits'))}</b>${item.tagline||item.description?`<p class="muted small" style="margin-top:5px">${esc(item.tagline||item.description)}</p>`:''}</article>`).join('')}</div>`:''}`;
}
function actionableWalletCardMarkup(card,{detail=false}={}){
  const business=card?.business||{},loyalty=card?.loyalty||{},credit=card?.credit||{},packages=card?.packages||{};
  const unit=esc(loyalty.unit||'points'),currency=esc(business.currency||'SGD'),reward=card?.next_eligible_reward||null,visit=card?.visit_progress||{};
  return `<article class="card wallet-section${detail?' customer-game-card':''}"${detail?'':' style="margin:0"'}>
    <div class="row"><div><h2>${esc(business.name||'Business')} rewards</h2><p class="muted small" style="margin-top:4px">${esc(business.industry||'Local business')}</p></div><span class="spacer"></span>${detail?'':`<span class="pill">${esc(actionableWalletActionText(card))}</span>`}</div>
    <div class="wallet-metrics">
      <div class="wallet-metric"><span class="muted small">${unit} balance</span><b>${esc(customerPointTotalV103(loyalty.balance||0))}</b></div>
      <div class="wallet-metric"><span class="muted small">Credit balance</span><b>${currency} ${(Number(credit.balance_cents||0)/100).toFixed(2)}</b></div>
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
  toast('+'+increase+' '+safeUnit+' earned!');
  customerSuccessCue();
}
function customerSuccessCue(){
  if(!customerCelebrationSoundEnabled)return;
  if(globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches)return;
  try{globalThis.navigator?.vibrate?.(35)}catch{}
  try{
    const AudioContext=globalThis.AudioContext||globalThis.webkitAudioContext;
    if(!AudioContext)return;
    const audio=new AudioContext(),gain=audio.createGain(),oscillator=audio.createOscillator();
    oscillator.type='sine';oscillator.frequency.setValueAtTime(660,audio.currentTime);
    oscillator.frequency.exponentialRampToValueAtTime(990,audio.currentTime+.16);
    gain.gain.setValueAtTime(.0001,audio.currentTime);gain.gain.exponentialRampToValueAtTime(.12,audio.currentTime+.02);gain.gain.exponentialRampToValueAtTime(.0001,audio.currentTime+.28);
    oscillator.connect(gain);gain.connect(audio.destination);oscillator.start();oscillator.stop(audio.currentTime+.3);
    oscillator.onended=()=>audio.close();
  }catch{}
}
function renderCustomerFirstProgrammeQuest(){
  setCustomerSurfaceDocumentV167();
  globalThis.document?.documentElement?.setAttribute('lang','en');
  root.innerHTML=`<div class="wallet-shell customer-surface"><div class="wallet-inner"><header class="wallet-head"><a class="logo" href="#/wallet">${brandWordmark()}</a><span class="spacer"></span><details class="customer-account-menu"><summary class="customer-avatar" aria-label="${esc(ct('accountMenu'))}">${CUI.icon('customers',{size:20})}</summary><div class="menu"><a href="#/customer/profile">${CUI.icon('customers',{size:17})}<span>${esc(ct('profilePasskeys'))}</span></a><button id="walletSignOut" type="button">${CUI.icon('back',{size:17})}<span>${esc(ct('signOut'))}</span></button></div></details></header>
    <main id="main" tabindex="-1"><section class="card customer-first-quest" aria-labelledby="firstProgrammeTitle"><div class="customer-first-quest-copy"><p class="customer-quest-kicker">${esc(ct('firstQuest'))}</p><div class="customer-first-quest-icon">${CUI.icon('scan',{size:38})}</div><h1 id="firstProgrammeTitle">${esc(ct('scanLoyaltyQr'))}</h1><p class="muted">${esc(ct('firstQuestBody'))}</p><button class="btn" id="customerFirstScan" type="button">${CUI.icon('scan',{size:20})}<span>${esc(ct('scanBusinessQr'))}</span></button><p class="muted small" style="margin-top:16px">${esc(ct('qrOnlyHelp'))}</p></div></section></main>${legalLinks()}</div></div>`;
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
    creditCents=Math.max(0,Number(card?.credit?.balance_cents)||0),
    currency=String(business.currency||'SGD');
  const chips=[];
  if(sessions>0)chips.push(`<span class="customer-programme-holding"><b>${sessions}</b> ${esc(sessions===1?'session left':'sessions left')}</span>`);
  if(creditCents>0)chips.push(`<span class="customer-programme-holding"><b>${esc(currency)} ${(creditCents/100).toFixed(2)}</b> credit</span>`);
  return chips.length?`<div class="customer-programme-holdings">${chips.join('')}</div>`:'';
}
function customerProgrammeTileMarkupV96(card){
  const business=card?.business||{},loyalty=card?.loyalty||{},reward=card?.next_eligible_reward||null;
  const accent=contrastSafeBrandColor(/^#[0-9a-f]{6}$/i.test(String(business.brand_color||''))?business.brand_color:'#c73b2f');
  const unit=ct(String(loyalty.unit||'points').toLowerCase()==='stamps'?'stamps':'points');
  const holdings=customerProgrammeHoldingsMarkupV183(card);
  return `<a class="card customer-programme-card customer-programme-card-v95" data-programme-name="${esc(String(business.name||'').toLowerCase())}" style="--merchant-accent:${esc(accent)}" href="#/wallet/${encodeURIComponent(business.slug||'')}" aria-label="${esc(ct('openProgramme',{business:business.name||ct('localBusiness')}))}"><div class="customer-programme-card-accent"></div><div class="customer-programme-card-body"><div class="customer-programme-logo">${customerProgrammeTileLogoV96(business)}</div><div class="customer-programme-card-copy">${business.industry?`<p class="customer-quest-kicker">${esc(business.industry)}</p>`:''}<h2>${esc(business.name||ct('localBusiness'))}</h2>${reward?.available_now===true?`<p class="muted small" style="margin-top:4px">${esc(ct('rewardReady'))}</p>`:''}</div><div class="customer-programme-card-balance"><b>${esc(customerPointTotalV103(loyalty.balance||0))}</b><span>${esc(unit)}</span></div>${holdings?`<div style="grid-column:1/-1">${holdings}</div>`:''}${reward?`<div style="grid-column:1/-1">${customerRewardProgressMarkupV167(card)}</div>`:''}</div></a>`;
}
function customerBusinessCategoryV122(industry=''){
  const value=String(industry||'').trim().toLowerCase();
  if(/facial|spa|salon|beauty|hair|massage|personal care|aesthetic|wellness/.test(value))
    return 'Personal care';
  if(/cafe|café|coffee|restaurant|food|beverage|f&b|fnb|bakery|bar/.test(value))
    return 'Food & drink';
  if(/fitness|gym|yoga|pilates|sport/.test(value))return 'Fitness';
  if(/retail|shop|fashion|boutique|grocer/.test(value))return 'Shopping';
  return 'Other';
}
function customerProgrammeGridMarkupV96(cards=[]){
  const order=['Personal care','Food & drink','Fitness','Shopping','Other'];
  const grouped=new Map(order.map(category=>[category,[]]));
  cards.forEach(card=>grouped.get(customerBusinessCategoryV122(card?.business?.industry)).push(card));
  return `<div class="customer-programme-list customer-programme-grid-v96">${order
    .filter(category=>grouped.get(category).length)
    .map(category=>`<section class="customer-programme-category" aria-labelledby="customerCategory-${category.replaceAll(' ','-').toLowerCase()}">
      <div class="customer-programme-category-head"><h2 id="customerCategory-${category.replaceAll(' ','-').toLowerCase()}">${esc(category)}</h2><span class="pill">${grouped.get(category).length}</span></div>
      <div class="customer-programme-category-grid">${grouped.get(category).map(customerProgrammeTileMarkupV96).join('')}</div>
    </section>`).join('')}</div>`;
}
/* v178 (owner annotation): the crossed-out page-head title block is gone from Home, so the
   "Scan to join" control lives in this section heading row instead of a separate header. */
/* v195 (owner struck the subtitle out and drew a search field beside the title): the count was
   already visible — the tab badge carries it and every category prints its own — so the line only
   repeated. The search filters the tiles already on the page: no request, no spinner, and a
   customer with twenty reward accounts can reach one by typing its name. */
function customerMyRewardsHeadingV156(count=0,{scanId=''}={}){
  return `<div class="customer-my-rewards-title"><div><h2>${esc(ct('yourProgrammes'))}</h2></div>
    <div class="customer-my-rewards-search"><label class="sr-only" for="customerProgrammeSearch">Search company name</label>
      ${CUI.icon('search',{size:17})}<input id="customerProgrammeSearch" type="search" autocomplete="off" placeholder="Search company name" aria-describedby="customerProgrammeSearchStatus"></div>
    ${scanId?`<button class="btn sm" id="${esc(scanId)}" type="button">${CUI.icon('scan',{size:18})}<span>${esc(ct('addProgramme'))}</span></button>`:''}</div>
    <p class="muted small" id="customerProgrammeSearchStatus" role="status" hidden></p>`;
}
/* Filtering is done on the rendered tiles rather than by re-rendering, so a keystroke never
   re-reads the wallet and an empty search restores every tile exactly as the server sent it. */
function wireCustomerProgrammeSearchV195(host=document){
  const input=host.querySelector('#customerProgrammeSearch');
  if(!input)return;
  const status=host.querySelector('#customerProgrammeSearchStatus');
  const tiles=[...host.querySelectorAll('[data-programme-name]')];
  const groups=[...host.querySelectorAll('.customer-programme-category')];
  const apply=()=>{
    const query=String(input.value||'').trim().toLowerCase();
    let shown=0;
    tiles.forEach(tile=>{
      const match=!query||String(tile.dataset.programmeName||'').includes(query);
      tile.hidden=!match;
      if(match)shown++;
    });
    groups.forEach(group=>{
      const visible=[...group.querySelectorAll('[data-programme-name]')].some(tile=>!tile.hidden);
      group.hidden=!visible;
    });
    if(!status)return;
    status.hidden=!query;
    status.textContent=query?(shown?`${shown} of ${tiles.length} shown`:`No reward account matches “${query}”.`):'';
  };
  input.addEventListener('input',apply);
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
  return `<section class="card customer-first-quest customer-home-empty-action" aria-labelledby="customerHomeEmptyTitle"><div class="customer-first-quest-copy"><div class="customer-first-quest-icon">${CUI.icon('scan',{size:34})}</div><h2 id="customerHomeEmptyTitle">${esc(ct('scanLoyaltyQr'))}</h2><p class="muted small">${esc(ct('firstQuestBody'))}</p><button class="btn" id="customerHomeScan" type="button">${CUI.icon('scan',{size:20})}<span>${esc(ct('scanBusinessQr'))}</span></button><p class="muted small" style="margin-top:12px">${esc(ct('qrOnlyHelp'))}</p></div></section>`;
}
/* v244: the v242 "All businesses" directory moved off the bottom of Home into the Explore tab,
   where it is the empty-query result of the ecosystem search. Same rules (an unjoined business
   never navigates, never shows points); Home stays offers-first. */
/* v194 (owner struck both cards out on Home): the two quick links repeated the primary nav
   directly above them — My Rewards and Bookings are already one tap away in the tab bar, and
   the counts they carried now live on those tabs. Home is the offers shelf. */
/* v178: surface='programmes' is the "My Rewards" tab, which the owner stripped back to the
   reward-account grid alone — no offers shelf, no guidance banner. Home keeps both. */
function renderActionableWalletHome(payload,{offersState={status:'loading',items:[]},legacyCards=[],pendingRedemption=null,surface='home',rerender=null}={}){
  const cards=Array.isArray(payload?.cards)?payload.cards:[],isHome=surface!=='programmes';
  const repaint=typeof rerender==='function'?rerender:()=>renderCustomerWallet();
  if(!cards.length){
    $('walletBody').innerHTML=`${isHome?customerHomeOffersMarkupV167(offersState):''}<section class="card customer-first-quest" aria-labelledby="firstProgrammeTitle"><div class="customer-first-quest-copy"><p class="customer-quest-kicker">${esc(ct('firstQuest'))}</p><div class="customer-first-quest-icon">${CUI.icon('scan',{size:38})}</div><h1 id="firstProgrammeTitle">${esc(ct('scanLoyaltyQr'))}</h1><p class="muted">${esc(ct('firstQuestBody'))}</p><button class="btn" id="customerFirstScan" type="button">${CUI.icon('scan',{size:20})}<span>${esc(ct('scanBusinessQr'))}</span></button><p class="muted small" style="margin-top:16px">${esc(ct('qrOnlyHelp'))}</p></div></section>`;
    $('customerFirstScan').onclick=openCustomerJoinScanner;
    wireCustomerHomeOffersV167(repaint);
    return;
  }
  /* v183 (owner annotation: the whole "My Rewards" block struck through on Home): the reward
     grid is the My Rewards tab's job. Home is now offers first, then a two-way jump-off. */
  const homeGuidance=isHome?customerHomeGuidanceV167({pendingRedemption,actionableCards:cards,legacyCards,offers:offersState.items}):'';
  /* v286: "everything resolved and there is nothing" is a real state, not a loading state — only
     claim it once offers have actually come back ready, never while loading or on an error. */
  const homeEmpty=isHome&&!homeGuidance&&offersState.status==='ready'
    &&!(Array.isArray(offersState.items)&&offersState.items.length)&&!customerExpiringRowsV286(cards).length;
  $('walletBody').innerHTML=`${isHome?`${customerExpiringRewardsMarkupV195(cards)}
    ${customerHomeOffersMarkupV167(offersState)}
    ${homeGuidance}${homeEmpty?customerHomeEmptyActionV286():''}`
    :`${customerMyRewardsHeadingV156(cards.length,{scanId:'customerHomeScan'})}
    ${customerProgrammeGridMarkupV96(cards)}
    ${payload?.truncated?`<div class="card customer-home-summary-note" role="status"><p class="muted small">Showing the 100 highest-priority linked reward accounts.</p></div>`:''}`}`;
  if($('customerHomeScan'))$('customerHomeScan').onclick=openCustomerJoinScanner;
  if(!isHome)wireCustomerProgrammeSearchV195($('walletBody'));
  wireCustomerHomeOffersV167(repaint);
}
async function renderCustomerWallet(businessSlug=null){
  const walletRenderEpoch=++customerWalletRenderEpoch;
  const isWalletCurrent=()=>customerWalletRenderEpoch===walletRenderEpoch;
  const context=await loadCustomerSurfaceContext(isWalletCurrent);if(!context)return;
  const customerFeatures=context.features;
  renderCustomerShell({active:businessSlug?'programmes':'home',businessSlug,staffWorkspaces:context.staffWorkspaces,messagesAvailable:customerFeatures.customer_in_app_inbox===true,
    body:`<div class="card"><p class="muted">Loading ${esc(BRAND.customerLabel)}…</p></div>`});
  let actionableCard=null,programmeCards=[];
  if(customerFeatures.customer_actionable_wallet===true){
    if(!businessSlug){
      const {data,error}=await customerRpc('customer_get_actionable_wallet');
      if(!isWalletCurrent())return;
      if(!error&&Array.isArray(data?.cards)&&data.cards.length){
        /* v286: this pair used raw sb.rpc, so it carried NO abortSignal while every other read in
           the Promise.all aborts at 12s (v177) — and Promise.all waits for the slowest, so one
           stalled multi-business inbox sync left Home on "Loading Peekaa…" forever with no error
           and no Retry. Both calls now go through customerRpc, AND the badge no longer gates the
           paint: Home renders from the wallet/bookings/offers reads and the bell slot hydrates
           when the count lands. */
        const messagePromise=customerFeatures.customer_in_app_inbox===true
        ?(async()=>{
          const syncResult=await customerRpc('customer_sync_in_app_inbox_global',{p_idempotency_key:crypto.randomUUID()});
          if(syncResult.error)return {data:null,error:syncResult.error};
          return customerRpc('customer_get_in_app_inbox_global_count');
        })().catch(error=>({data:null,error}))
        :Promise.resolve({data:null,error:null});
      const [legacyResult,bookingRequestResult,offersResult]=await Promise.all([
        customerRpc('customer_get_wallet'),
        customerRpc('customer_get_booking_requests',{p_limit:50,p_cursor:null}),
        customerRpc('customer_get_home_offers_v167',{p_locale:'en'})
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
      renderActionableWalletHome(data,{
        legacyCards:customerHomeOverview.walletCards,
        offersState:offersResult.error?{status:'error',items:[]}:{status:'ready',items:Array.isArray(offersResult.data?.items)?offersResult.data.items:[]},
        pendingRedemption:offersResult.error?null:offersResult.data?.pending_redemption||null
      });
      /* v194: My Rewards counts the REWARD ACCOUNTS this customer holds; Bookings counts what is
         still live — a request awaiting the business plus an upcoming appointment. Both come from
         data already fetched above, so neither badge costs a round trip. */
      applyCustomerNavCountsV194({
        programmes:Array.isArray(data?.cards)?data.cards.length:0,
        bookings:customerHomeOverview.activeRequestCount
          +customerHomeOverview.walletCards.reduce((total,card)=>
            total+Math.max(0,Number(card?.upcoming_appointments?.count||0)),0)
      });
      const paintCustomerInboxBellV286=unread=>{
        const inboxSlot=$('customerInboxBellSlot');
        if(!inboxSlot||customerFeatures.customer_in_app_inbox!==true)return;
        inboxSlot.innerHTML=`<a class="customer-inbox-bell" href="#/customer/messages" aria-label="${unread===null?'Open messages':`Open messages, ${unread} unread`}" title="Open messages">${CUI.icon('bell',{size:19})}${Number(unread)>0?`<span class="customer-inbox-badge" aria-hidden="true">${unread>99?'99+':unread}</span>`:''}</a>`;
      };
      paintCustomerInboxBellV286(customerHomeOverview.messageCount);
      /* v286: same epoch guard as every other post-await write — a slow badge from an abandoned
         render must never repaint the surface the customer moved on to. */
      messagePromise.then(messageResult=>{
        if(!isWalletCurrent())return;
        customerHomeOverview.messageCount=messageResult?.error?null:Math.max(0,Number(messageResult?.data?.unread_count||0));
        paintCustomerInboxBellV286(customerHomeOverview.messageCount);
      });
      focusCustomerRoute();
      return;
      }
    }
    if(businessSlug){
      const [{data,error},walletResult]=await Promise.all([
        customerRpc('customer_get_actionable_business',{p_business_slug:businessSlug}),
        customerRpc('customer_get_actionable_wallet')
      ]);
      if(!isWalletCurrent())return;
      /* V289: 42501 is "you hold no link to this business", not a load failure. */
      if(walletRpcDenied(error))return renderCustomerNotJoinedV289(businessSlug);
      if(error)return renderCustomerWalletRetry('This business could not be loaded.',businessSlug,undefined,error);
      actionableCard=data?.card||null;
      programmeCards=walletResult.error?[]:(Array.isArray(walletResult.data?.cards)?walletResult.data.cards:[]);
      if(!actionableCard)return renderCustomerNotJoinedV289(businessSlug);
    }
  }
  if(!businessSlug){
    const [{data,error},bookingRequestResult,selectorMediaResult,offersResult]=await Promise.all([
      customerRpc('customer_get_wallet'),
      customerRpc('customer_get_booking_requests',{p_limit:50,p_cursor:null}),
      customerRpc('customer_get_programme_selector_media_v96'),
      customerRpc('customer_get_home_offers_v167',{p_locale:'en'})
    ]);
    if(!isWalletCurrent())return;
    if(error)return renderCustomerWalletRetry('Your wallet is temporarily unavailable.',null,undefined,error);
    const cards=mergeCustomerProgrammeSelectorMediaV96(
      Array.isArray(data)?data:[],selectorMediaResult.error?null:selectorMediaResult.data
    );
    const appointmentCount=cards.reduce((sum,card)=>sum+Math.max(0,Number(card?.upcoming_appointments?.count||0)),0);
    const activeRequestCount=bookingRequestResult.error?0:(Array.isArray(bookingRequestResult.data?.items)?bookingRequestResult.data.items.filter(isActiveCustomerBookingRequest).length:0);
    const bookingCount=appointmentCount+activeRequestCount;
    const bookingsAvailable=!bookingRequestResult.error||cards.length>0;
    const offersState=offersResult.error?{status:'error',items:[]}:{status:'ready',items:Array.isArray(offersResult.data?.items)?offersResult.data.items:[]};
    $('walletBody').innerHTML=`${customerHomeOffersMarkupV167(offersState)}
      ${customerHomeFallbackActionV167({pendingRedemption:offersResult.error?null:offersResult.data?.pending_redemption||null,legacyCards:cards,offers:offersState.items})}
      ${cards.length?'':`<div class="card"><h2>No verified business links yet</h2><p class="muted small" style="margin-top:6px">Scan a participating business’s Peekaa QR during your visit. Peekaa does not let customers search for or self-link a business from this portal.</p></div>`}
      `;
    /* v194: the fallback Home carries the same nav badges as the primary path — a customer who
       lands here through the legacy read must not see empty tabs where the other path shows
       counts. A booking read that failed contributes 0, never a guess. */
    applyCustomerNavCountsV194({programmes:cards.length,bookings:bookingsAvailable?bookingCount:0});
    if($('customerHomeScan'))$('customerHomeScan').onclick=openCustomerJoinScanner;
    wireCustomerHomeOffersV167(()=>renderCustomerWallet());
    focusCustomerRoute();
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
  if(walletRpcDenied(summaryError)||walletRpcDenied(capabilitiesError))return renderCustomerNotJoinedV289(businessSlug);
  if(summaryError||capabilitiesError)return renderCustomerWalletRetry('This business could not be loaded.',businessSlug,undefined,summaryError||capabilitiesError);
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
  if(businessId)typeof recordProductInteractionV100==='function'&&recordProductInteractionV100('customer.programme_viewed',businessId,{
      context:{entry_point:'customer_wallet',locale:customerLocale,surface_version:'v100'}
    });
  if(businessId){
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
    businessId?sb.rpc('customer_get_business_presentation_v95',{p_business:businessId,p_branch:null,p_locale:customerLocale==='zh-CN'?'zh-CN':'en'}):unavailableBusinessId(), /* v293: merchant programme copy is bilingual (en/zh-CN); ms wallets read the English merchant copy */
    businessId?sb.rpc('customer_get_effective_tier_v143',{p_business:businessId}):unavailableBusinessId(),
    /* V201 (owner: "customer view only have 1 company instead of multiple branch"). The customer
       sees the FIRM, so this read is firm-wide by definition — never the workspace's selected
       branch. selectedBranchId is workspace state; a staff member who is also a customer would
       otherwise carry their branch scope into their own customer view and silently lose the other
       outlets' offers. A promotion that only runs at one outlet says so in its own terms. */
    businessId?sb.rpc('customer_get_promotions_v155',{p_business:businessId,p_branch:null,p_locale:'en'}):unavailableBusinessId(),
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
  presentation.offers=promotionsResult.error
    ?[]
    :(Array.isArray(promotionsResult.data?.items)?promotionsResult.data.items:[]).slice(0,6);
  /* v255 (audit finding: promotion views were class C — nothing recorded between "we published
     it" and "someone redeemed"). Deduped per browser session so a wallet the customer reopens
     five times is one view, not five. */
  if(businessId)for(const offerV256 of presentation.offers){
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
  const showCreditMetric=loyalty.enabled===true&&Number(loyalty.credit_balance_cents||0)>0;
  const showPackageMetric=capabilities.packages===true&&Number(packages.sessions_remaining||0)>0;
  const showMembershipMetric=capabilities.membership===true&&membership.active===true;
  const showSecondaryMetrics=!actionableCard&&(showCreditMetric||showPackageMetric||showMembershipMetric);
  const hasWalletSection=true;
  $('walletBody').innerHTML=`${customerMerchantExperienceMarkupV95({presentation,business:b,actionableCard,programmeCards,bookingEnabled:capabilities.booking_request&&bookingEnabled,offersStatus:programmeOffersStatus,rewardsHost:capabilities.rewards===true,programmeCapabilities:capabilities})}
    ${showSecondaryMetrics?`<div class="wallet-metrics">
      ${showCreditMetric?`<div class="wallet-metric"><span class="muted small">Store credit</span><b>${esc(currency)} ${(Number(loyalty.credit_balance_cents)/100).toFixed(2)}</b></div>`:''}
      ${showPackageMetric?`<div class="wallet-metric"><span class="muted small">Package sessions</span><b>${Number(packages.sessions_remaining)}</b></div>`:''}
      ${showMembershipMetric?`<div class="wallet-metric"><span class="muted small">Membership</span><b>Active</b></div>`:''}
    </div>`:''}
    <div class="wallet-sections" id="walletSections">
      ${window.NestlyGrowthOffers?window.NestlyGrowthOffers.renderCustomerOffers({state:'loading'}):''}
      <details class="card wallet-history-disclosure" id="walletHistoryDisclosure">
        <summary><span>History</span><span class="muted small">Transactions and loyalty activity</span></summary>
        <div class="wallet-history-disclosure-body">
          ${walletSectionShell('walletTransactions','Transactions & points','Every purchase, reversal, correction, and points event kept in time order.')}
          ${capabilities.activity?walletSectionShell('walletActivity','Loyalty activity','Your loyalty history with this business.'):''}
        </div>
      </details>
      ${walletSectionShell('walletGiftCards','Gift cards','Money left on your gift cards from this business.')}
      ${capabilities.packages?walletSectionShell('walletPackages','Packages','Session balances and recent usage.'):''}
      ${capabilities.membership?walletSectionShell('walletMemberships','Membership','Current plan and period status.'):''}
      ${capabilities.appointments?walletSectionShell('walletAppointments','Appointments','Upcoming and recent visits.'):''}
      ${walletReviewUrlV183(b)?`<section class="card wallet-section" id="walletFeedback"></section>`:''}
      ${customerFeatures.customer_birthday_benefits&&actionableCard?.birthday_benefit&&actionableCard.birthday_benefit.status!=='unavailable'?`<section class="card wallet-section" id="walletBirthdayParticipation" aria-busy="true"><div class="wallet-skeleton"></div></section>`:''}
      ${hasWalletSection?'':`<section class="card wallet-section" id="walletEmpty"><div class="wallet-section-head"><div><h2>Nothing to show yet</h2><p class="muted small">This business has no customer wallet sections available for your account.</p></div><span class="spacer"></span><button class="btn ghost sm" id="walletEmptyRetry">Refresh</button></div></section>`}
    </div>`;
  wireCustomerRepeatBookingV167($('walletBody'));
  wireCustomerProgrammeTabsV194($('walletBody'));
  /* v194: the header identity opens the same company sheet the offer sheet uses. */
  $('walletBody').querySelectorAll('[data-company-detail]').forEach(button=>button.onclick=()=>
    showCustomerBusinessDetailV178({...b,id:businessId||b.id,slug:businessSlug}));
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
  /* v265: Share reads the offer back out of the list the page already rendered, so the sheet can
     never describe a different promotion from the card that was tapped. */
  document.querySelectorAll('[data-share-offer]').forEach(button=>button.onclick=()=>{
    const offerId=String(button.dataset.shareOffer||'');
    const offer=(Array.isArray(presentation.offers)?presentation.offers:[]).find(item=>String(item?.id||'')===offerId);
    if(offer)shareCustomerOfferV264(offer,{...b,id:businessId||b.id,slug:businessSlug});
  });
  document.querySelector('[data-programme-offers-retry]')?.addEventListener('click',()=>renderCustomerWallet(businessSlug));
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
  showCustomerPromotionPopupV122({
    business:b,businessSlug,items:presentation.offers,
    prompt:promotionPromptResult.error?null:promotionPromptResult.data
  });
  focusCustomerRoute();
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
    const [catalogResult,actionsResult]=await Promise.all([
      customerRpc('customer_get_reward_catalog',args),
      businessId?customerRpc('customer_get_business_actions_v89',{p_business:businessId}):unavailableBusinessId()
    ]);
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
    if(!rewards.length)return walletSectionEmpty('walletRewards','Rewards',ct('No rewards are available right now.'),businessSlug,'rewards',loadRewards,isWalletCurrent);
    const availability={
      available_at_counter:'Available at counter',
      disabled:'Unavailable for redemption',
      insufficient_balance:'More points needed',
      not_started:'Available soon',
      ended:'Offer ended',
      limit_reached:'Claim limit reached',
      tier_locked:'Unlocks at a higher tier'
    };
    /* A tier-gated reward stays VISIBLE and locked rather than hidden: naming the tier is the
       whole reason a member climbs. Uses the tier name the server resolved, so this line can
       never disagree with what the counter will actually allow. */
    const rewardLockLineV176=(r)=>{
      if(r.availability!=='tier_locked')return '';
      const label=r.tier_requirement?.tier_label;
      return label?`Reach ${label} to unlock this reward`:'Unlocks at a higher tier';
    };
    /* v286: with redemption unchecked, "Available at counter" is a claim this page cannot stand
       behind — the honest line is that we could not check. Every other status (tier-locked, short
       of points, ended) comes from the catalog and the balance, so those stay true and unchanged. */
    if(redemptionUncheckedV286)availability.available_at_counter='Redemption can’t be checked right now';
    host.setAttribute('aria-busy','false');
    const rewardUnit=loyalty.unit||'points',rewardBalance=Math.max(0,Number(loyalty.balance)||0);
    /* v195: this now renders inside the Reward points tab, which already prints the balance in
       full. The repeated balance and the three-step "how rewards work" strip went with the card
       the owner crossed out; one line of instruction survives, on the control it describes. */
    host.innerHTML=`${redemptionUncheckedV286
      ?`<div class="wallet-section-head" data-rewards-redemption-unchecked><div><h2>Redemption can’t be checked right now</h2><p class="muted small">These rewards are shown for reference only — we could not reach this business’s redemption settings, so no QR can be issued yet.</p></div><span class="spacer"></span><button class="btn ghost sm" type="button" id="walletRewardsRedemptionRetry">Retry</button></div>`
      :`<p class="muted small customer-programme-rewards-lede">Pick a reward, then show its QR at the counter — staff scan it and the ${esc(rewardUnit)} come off.</p>`}
      <div class="wallet-rewards">${rewards.map(r=>{
      const ready=!!(r.action_key&&customerRewardCanRedeem(r,redemptionEnabled)),
        cost=Math.max(0,Number(r.cost_points)||0),gap=Math.max(0,cost-rewardBalance),
        progress=cost>0?Math.min(100,Math.max(0,Math.round((rewardBalance/cost)*100))):100,
        short=r.availability==='insufficient_balance';
      return `<article class="wallet-reward">
      ${r.image_ref?(String(r.image_ref).startsWith('https://')?`<p class="small" style="margin-bottom:9px"><a href="${esc(r.image_ref)}" target="_blank" rel="noopener noreferrer">View reward image</a></p>`:`<img src="${esc(r.image_ref)}" alt="" loading="lazy">`):''}<div class="row"><b class="wallet-reward-trade"><span class="wallet-reward-cost">${esc(customerPointTotalV103(cost))} ${esc(rewardUnit)}</span><span class="wallet-reward-arrow" aria-hidden="true">→</span><span>${esc(r.customer_name||'Reward')}</span></b><span class="spacer"></span>${ready?'<span class="pill ok">Ready</span>':''}${r.availability==='tier_locked'?'<span class="pill">🔒 Locked</span>':''}</div>
      ${customerRewardDescriptionV183(r.description)?`<p class="muted small" style="margin-top:7px">${esc(customerRewardDescriptionV183(r.description))}</p>`:''}${short?`<div class="wallet-reward-progress" aria-hidden="true" style="--reward-progress:${progress}%"><span></span></div><p class="small wallet-reward-gap"><b>${esc(customerPointTotalV103(gap))} more ${esc(rewardUnit)}</b></p><span class="sr-only">${esc(customerPointTotalV103(rewardBalance))} of ${esc(customerPointTotalV103(cost))} ${esc(rewardUnit)} collected.</span>`:''}<p class="${short?'muted small':'small'}" style="margin-top:9px">${esc(rewardLockLineV176(r)||availability[r.availability]||'Ask at counter')}</p>
      ${r.entitlement_expiry_days?`<p class="muted small" style="margin-top:5px">Use within ${Number(r.entitlement_expiry_days)} days after claim.</p>`:''}
      ${r.eligibility?`<p class="muted small" style="margin-top:5px">${[['branches','locations'],['services','services'],['products','products']].filter(([key])=>r.eligibility[key]?.scope==='restricted').map(([key,label])=>`${Number(r.eligibility[key].count||0)} eligible ${label}`).join(' · ')||'Valid across all eligible services and locations.'}</p>`:''}
      ${r.instructions?`<details style="margin-top:9px"><summary class="small">How to use</summary><p class="muted small" style="margin-top:5px">${esc(r.instructions)}</p></details>`:''}
      ${r.terms?`<details style="margin-top:9px"><summary class="small">Terms</summary><p class="muted small" style="margin-top:5px">${esc(r.terms)}</p></details>`:''}
      <div class="wallet-reward-actions">${ready
        ?`<button class="btn sm" type="button" data-customer-redeem="${esc(r.action_key)}">${CUI.icon('scan',{size:17})}<span>Show QR at counter</span></button>`
        :''}</div></article>`}).join('')}</div>`;
    if($('walletRewardsRedemptionRetry'))$('walletRewardsRedemptionRetry').onclick=loadRewards;
    let redemptionAttempt=null;
    host.querySelectorAll('[data-customer-redeem]').forEach(button=>button.onclick=async()=>{
      const reward=rewards.find(item=>item.action_key===button.dataset.customerRedeem);
      if(!reward)return;
      if(!redemptionAttempt||redemptionAttempt.actionKey!==reward.action_key){
        redemptionAttempt={actionKey:reward.action_key,key:crypto.randomUUID()};
      }
      button.disabled=true;button.querySelector('span').textContent='Preparing QR…';
      const {data:intent,error:intentError}=await sb.rpc('customer_create_redemption_intent_v89',
        customerRedemptionIntentArgsV89({
          businessId,reward,idempotencyKey:redemptionAttempt.key
        }));
      if(!isWalletSectionCurrent(host)||!button.isConnected)return;
      button.disabled=false;button.querySelector('span').textContent='Show QR at counter';
      if(intentError){
        toast(intentError.code==='PGRST202'||intentError.code==='42883'
          ?'Something’s not working right now. Please try again shortly.'
          :'This reward could not be prepared. Refresh its balance and try again.');
        return;
      }
      if(intent?.status==='completed'||intent?.status==='redeemed'){
        redemptionAttempt=null;toast('This reward is already redeemed');loadRewards();loadTransactions(null);return;
      }
      if(intent?.status!=='pending'||!intent?.qr_token){
        toast(CUSTOMER_REDEMPTION_STATUS_COPY[String(intent?.status||'')]||'This reward can’t be used right now.');return;
      }
      showPendingRedemptionQr({intent,businessName:b.name,rewardName:reward.customer_name||reward.name,onClose:()=>loadRewards()});
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
    host.innerHTML=`<div class="wallet-section-head"><div><h2>Loyalty activity</h2>${Number(expiry.expiring_next_30_days||0)>0?`<p class="muted small">${esc(customerPointTotalV103(expiry.expiring_next_30_days))} ${unit} expire within 30 days${expiry.next_expiry_at?' · next '+esc(walletDate(expiry.next_expiry_at)):''}.</p>`:'<p class="muted small">Your loyalty history with this business.</p>'}</div></div>
      <div>${activityState.items.map(item=>{const delta=Number(item.points_delta||0),campaign=campaignEntitlementDisplayV99(item);return `<div class="wallet-line"><div><b>${esc(campaign.title||'Loyalty activity')}</b><p class="muted small" style="margin-top:3px">${esc(walletDate(item.event_at,true))}${campaign.status?' · '+esc(campaign.status.replaceAll('_',' ')):''}</p>${campaign.detail?`<p class="muted small" style="margin-top:3px">${esc(campaign.detail)}</p>`:''}</div><span class="spacer"></span>${campaign.pending?'<span class="pill off">Pending with business</span>':`<span class="wallet-delta ${delta>0?'plus':delta<0?'minus':''}">${delta>0?'+':delta<0?'−':''}${esc(customerPointTotalV103(Math.abs(delta)))} ${unit}</span>`}</div>`}).join('')}</div>
      ${activityState.nextCursor?'<button class="btn ghost sm" id="walletActivityMore" style="margin-top:12px">Load more</button>':''}`;
    if($('walletActivityMore'))$('walletActivityMore').onclick=()=>{ $('walletActivityMore').disabled=true;loadActivity(activityState.nextCursor) };
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
    if(!transactionState.items.length){
      host.innerHTML='<div class="wallet-section-head"><div><h2>Transactions &amp; points</h2><p class="muted small">No purchases or points activity has been recorded for this programme yet.</p></div></div>';
      return;
    }
    const historyCurrency=String(data?.business?.currency||currency);
    const historyMoney=cents=>`${historyCurrency} ${(Number(cents||0)/100).toFixed(2)}`;
    const historyItemMarkup=item=>{
        const earned=Number(item.points_earned||0),redeemed=Number(item.points_redeemed||0),removed=Number(item.points_removed||0);
        const gross=item.gross_cents===null||item.gross_cents===undefined?null:Number(item.gross_cents);
        const net=item.net_cents===null||item.net_cents===undefined?null:Number(item.net_cents);
        const lines=Array.isArray(item.line_items)?item.line_items:[];
        const packageLabel=item.is_package_session===true?'Package session used':(item.description||String(item.event_type||'Transaction').replaceAll('_',' '));
        const packageDetail=item.is_package_session===true?`${item.package_name||'Package'}${item.package_purchased_at?' · purchased '+walletDate(item.package_purchased_at):''}${item.package_reference?' · ref '+item.package_reference:''}`:'';
        return `<article class="wallet-line" style="align-items:flex-start"><div style="min-width:0;flex:1"><div class="row" style="align-items:flex-start"><div><b>${esc(packageLabel)}</b><p class="muted small" style="margin-top:3px">${esc(walletDate(item.event_at,true))}${item.status?' · '+esc(String(item.status).replaceAll('_',' ')):''}</p>${packageDetail?`<p class="muted small" style="margin-top:3px">${esc(packageDetail)}</p>`:''}</div><span class="spacer"></span>${net===null||item.is_package_session===true?'':`<b style="white-space:nowrap">${esc(historyMoney(net))}</b>`}</div>
          ${gross!==null&&net!==gross?`<p class="muted small" style="margin-top:5px">Original ${esc(historyMoney(gross))} · net after linked corrections ${esc(historyMoney(net))}</p>`:''}
          ${(earned||redeemed||removed)?`<p class="small" style="margin-top:6px">${earned?`<span class="wallet-delta plus">+${esc(customerPointTotalV103(earned))} points earned</span>`:''}${earned&&(redeemed||removed)?' · ':''}${redeemed?`<span class="wallet-delta minus">−${esc(customerPointTotalV103(redeemed))} points redeemed</span>`:''}${redeemed&&removed?' · ':''}${removed?`<span class="wallet-delta minus">−${esc(customerPointTotalV103(removed))} points removed</span>`:''}</p>`:''}
          ${lines.length?`<details style="margin-top:8px"><summary class="small">${lines.length} item${lines.length===1?'':'s'}</summary><div style="margin-top:5px">${lines.map(line=>`<div class="row small"><span>${Number(line.qty||0)} × ${esc(line.description||line.item_type||'Item')}</span><span class="spacer"></span><span>${esc(historyMoney(line.line_cents))}</span></div>`).join('')}</div></details>`:''}
        </div></article>`;
      };
    host.innerHTML=`<div class="wallet-section-head"><div><h2>Recent activity</h2><p class="muted small">Your latest ${Math.min(3,transactionState.items.length)} useful event${Math.min(3,transactionState.items.length)===1?'':'s'}.</p></div></div>
      <div class="wallet-history">${transactionState.items.slice(0,3).map(historyItemMarkup).join('')}</div>
      <details class="wallet-history-disclosure" style="margin-top:12px"><summary><span>Full history</span><span class="muted small">${transactionState.items.length} event${transactionState.items.length===1?'':'s'} shown · newest first</span></summary><div class="wallet-history-disclosure-body"><div class="wallet-history">${transactionState.items.map(historyItemMarkup).join('')}</div></div></details>
      ${transactionState.nextCursor?'<button class="btn ghost sm" id="walletTransactionsMore" style="margin-top:12px">Load more history</button>':''}`;
    const more=$('walletTransactionsMore');
    if(more)more.onclick=()=>{more.disabled=true;more.textContent='Loading…';loadTransactions(transactionState.nextCursor)};
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
    const giftState={active:'Ready to use',redeemed:'All used up',void:'Not valid'};
    host.setAttribute('aria-busy','false');
    host.innerHTML=`<div class="wallet-section-head"><div><h2>Gift cards</h2><p class="muted small">Show this screen at the counter — the team uses your card there. We never show the full card number.</p></div><span class="spacer"></span><span class="pill">${esc(giftMoney(data?.total_balance_cents))} left</span></div>
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
    host.innerHTML=`<div class="wallet-section-head"><div><h2>Packages</h2><p class="muted small">Session balances and recent usage.</p></div></div>${packageState.items.map(item=>`<div class="wallet-line"><div style="width:100%"><div class="row"><b>${esc(item.plan_name||'Package')}</b><span class="spacer"></span><span class="pill">${Number(item.sessions_remaining||0)} of ${Number(item.sessions_purchased||0)} left</span></div>
      <p class="muted small" style="margin-top:4px">${esc(String(item.status||'').replaceAll('_',' '))}${item.expires_at?' · expires '+esc(walletDate(item.expires_at)):''}</p>
      ${(item.usage_history||[]).length?`<div class="wallet-history">${collapsePackageUsageRuns(item.usage_history).map(use=>`<p class="muted small">${esc(walletDate(use.used_at,true))} · ${use.count>1?`${use.count} sessions ${esc(use.status)}`:esc(use.status)} · ${Number(use.remaining_after||0)} left</p>`).join('')}</div>`:''}</div></div>`).join('')}
      ${packageState.nextCursor?'<button class="btn ghost sm" id="walletPackagesMore" style="margin-top:12px">Load more</button>':''}`;
    if($('walletPackagesMore'))$('walletPackagesMore').onclick=()=>{ $('walletPackagesMore').disabled=true;loadPackages(packageState.nextCursor) };
  };
  const loadMemberships=async()=>{
    const host=$('walletMemberships');if(!host)return;
    const {data,error}=await customerRpc('customer_get_memberships',args);
    if(!isWalletSectionCurrent(host))return;
    if(error)return walletSectionError('walletMemberships',walletRpcDenied(error)?ct('Membership is not available for this account.'):ct('Membership could not be loaded.'),loadMemberships,error);
    const memberships=Array.isArray(data)?data:[];
    if(!memberships.length)return walletSectionEmpty('walletMemberships','Membership',ct('No membership is available for this account.'),businessSlug,'membership',loadMemberships,isWalletCurrent);
    host.setAttribute('aria-busy','false');
    host.innerHTML=`<div class="wallet-section-head"><div><h2>Membership</h2><p class="muted small">Current plan and period status.</p></div></div>${memberships.map(item=>`<div class="wallet-line"><div><b>${esc(item.plan_name||'Membership')}</b><p class="muted small" style="margin-top:3px">${esc(String(item.cadence||'').replaceAll('_',' '))}${item.current_period_start?' · '+esc(walletDate(item.current_period_start))+' to '+esc(walletDate(item.current_period_end)):''}</p></div><span class="spacer"></span><span class="pill">${esc(String(item.status||'').replaceAll('_',' '))}</span></div>`).join('')}`;
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
    sections.insertAdjacentHTML('afterbegin',`<section class="card wallet-section" id="walletBottles" data-section-title="Your bottles">
      <div class="wallet-section-head"><div><h2>Your bottles</h2><p class="muted small">What ${esc(b.name||'this bar')} is keeping for you. Show this screen at the counter to have one brought out.</p></div><span class="spacer"></span><span class="pill">${bottles.length}</span></div>
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
    host.innerHTML=`<div class="wallet-section-head"><div><h2>Rate your visit</h2><p class="muted small">Your review helps other people find ${esc(b.name||'this business')}.</p></div></div>
      <a class="btn sm" href="${esc(walletReviewUrl)}" target="_blank" rel="noopener noreferrer" style="margin-top:12px">${CUI.icon('loyalty',{size:17})}<span>Leave a public review</span></a>`;
  };
  await Promise.all([loadGrowthOffers(),loadRewards(),loadTransactions(),loadActivity(),loadGiftCards(),loadPackages(),loadMemberships(),loadAppointments(),loadBirthdayParticipation(),loadFeedback(),loadBottlesV275()]);
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
    slot.innerHTML=`<a class="customer-inbox-bell" href="#/customer/messages" aria-label="${unread?`Open messages, ${unread} unread`:'Open messages'}" title="${unread?`${unread} unread message${unread===1?'':'s'}`:'Open messages'}">${CUI.icon('bell',{size:19})}${unread?`<span class="customer-inbox-badge" aria-hidden="true">${unread>99?'99+':unread}</span>`:''}</a>`;
    return {unread};
  };
  const render=()=>{
    const status=[
      items.some(item=>item?.state==='source_unavailable')?'Some programme updates are temporarily unavailable and cannot be opened.':''
    ].filter(Boolean).join(' ');
    let priorBusinessSlug='';
    const renderedItems=items.map(item=>{
      const state=String(item?.state||'read'),isResolved=state==='resolved',isUnavailable=state==='source_unavailable',business=item?.business||null;
      const routeSlug=global?business?.slug:businessSlug;
      const deadline=item?.deadline_at?`<p class="muted small" style="margin-top:4px">Relevant until ${esc(walletDate(item.deadline_at))}.</p>`:'';
      const businessHeading=global&&business?.slug!==priorBusinessSlug?`<h3 class="customer-inbox-group">${esc(business?.name||'Business programme')}</h3>`:'';
      if(global&&business?.slug)priorBusinessSlug=business.slug;
      const stateCopy=isResolved?'Resolved history':isUnavailable?'Programme temporarily unavailable':state==='unread'?'Unread':'Read';
      const openAction=item?.action_available===true&&!isResolved&&item?.route_key==='wallet_business'&&routeSlug?`<button type="button" class="btn ghost sm" data-inbox-open="${esc(item.event_id)}" data-route-key="wallet_business">Open programme</button>`:'';
      const markAction=!isResolved?`<button type="button" class="btn ghost sm" data-inbox-state="${esc(item.event_id)}" data-state="${state==='unread'?'read':'unread'}">Mark ${state==='unread'?'read':'unread'}</button><button type="button" class="btn ghost sm" data-inbox-state="${esc(item.event_id)}" data-state="dismiss">Dismiss</button>`:'';
      return `${businessHeading}<article class="customer-inbox-item ${esc(state)}"><div class="row"><div><b>${esc(item?.title||'Inbox update')}</b><p class="muted small" style="margin-top:3px">${esc(item?.body||'')}</p>${deadline}</div><span class="spacer"></span><span class="pill">${esc(stateCopy)}</span></div><div class="customer-inbox-actions">${openAction}${markAction}</div></article>`;
    }).join('');
    host.setAttribute('aria-busy','false');
    host.innerHTML=`<div class="wallet-section-head"><div><h2>${global?`${esc(BRAND.customerLabel)} inbox`:'Inbox'}</h2><p class="muted small">${global?'Updates grouped by your separate business programmes.':'Customer-safe updates from this business.'}</p></div><span class="spacer"></span><button type="button" class="btn ghost sm customer-inbox-filter" data-inbox-filter="all" aria-pressed="${currentFilter==='all'}">All</button><button type="button" class="btn ghost sm customer-inbox-filter" data-inbox-filter="unread" aria-pressed="${currentFilter==='unread'}">Unread</button></div>
      <p id="customerInboxStatus" class="muted small" role="status" aria-live="polite">${esc(status)}</p>
      <div id="customerInboxItems">${items.length?renderedItems:'<p class="muted small" style="padding:8px 0">No '+(currentFilter==='unread'?'unread ':'')+'inbox updates right now.</p>'}</div>
      ${nextCursor?'<button type="button" class="btn ghost sm" id="customerInboxMore" style="margin-top:12px">Load more</button>':''}
      <div id="customerInAppInboxPreferences" style="margin-top:18px"></div>`;
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
    if(slotCurrent())slot.innerHTML=`<a class="customer-inbox-bell" href="#/customer/messages" aria-label="Open messages" title="Open messages">${CUI.icon('bell',{size:19})}</a>`;
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
  shell(CUI.loadingState({title:'Communications',body:'Loading your communication choices…',variant:'form'}));
  focusCustomerRoute();
  const {data,error}=await sb.rpc('customer_get_communication_preferences_v263');
  if(!isCurrent())return;
  if(error){
    shell(CUI.errorState({title:'Communications',message:'Your communication choices could not be loaded. Nothing has been changed.',retryId:'customerCommsRetry'}));
    const retry=$('customerCommsRetry');if(retry)retry.onclick=()=>renderCustomerCommunicationsV263();
    focusCustomerRoute();return;
  }
  const serverCategories=Array.isArray(data?.categories)?data.categories:[];
  const known=new Map(CUSTOMER_COMMUNICATION_CATEGORIES_V263.map(([key,label,help])=>[key,{label,help}]));
  const rows=serverCategories.filter(entry=>known.has(entry?.category));
  if(!rows.length){
    shell(`<header class="customer-page-head"><div><h1>Communications</h1></div></header>${CUI.emptyState({iconName:'bell',title:'No communication choices yet',body:'There is nothing to set here for your account right now.'})}`);
    focusCustomerRoute();return;
  }
  const allEnabled=data?.all_enabled===true;
  shell(`<header class="customer-page-head"><div><h1>Communications</h1><p class="muted">Everything is on unless you turn it off. Turning something off here never stops receipts, booking confirmations or security messages — those are not marketing and keep sending.</p></div></header>
    <section class="card"><label class="row" for="customerCommsAll" style="align-items:flex-start;color:var(--ink);font-weight:600"><input id="customerCommsAll" type="checkbox" ${allEnabled?'checked':''} style="width:20px;min-width:20px;min-height:20px;margin-top:2px"> <span>Send me all marketing messages<span class="muted small" style="display:block;font-weight:400;margin-top:3px">One tick covers every category and every channel below — push, email, SMS, WhatsApp and calls. You can switch any single one back off at any time.</span></span></label>
      <p class="muted small" id="customerCommsStatus" role="status" aria-live="polite" style="margin-top:10px"></p></section>
    ${rows.map(entry=>{
      const meta=known.get(entry.category);
      const channels=Array.isArray(entry.channels)?entry.channels:[];
      return `<section class="card" style="margin-top:14px"><h2>${esc(meta.label)}</h2><p class="muted small" style="margin-top:5px">${esc(meta.help)}</p>
      ${channels.map(channel=>{
        const label=(CUSTOMER_COMMUNICATION_CHANNELS_V263.find(([key])=>key===channel?.channel)||[null,channel?.channel])[1];
        return `<label class="row" for="customerComms-${esc(entry.category)}-${esc(channel.channel)}" style="margin-top:12px;color:var(--ink);font-weight:500"><input id="customerComms-${esc(entry.category)}-${esc(channel.channel)}" class="customerCommsToggle" type="checkbox" style="width:auto" data-category="${esc(entry.category)}" data-channel="${esc(channel.channel)}" ${channel.enabled===true?'checked':''}>${esc(label||channel.channel)}</label>`;
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
    input.disabled=true;say('Saving…');
    const {error:setError}=await sb.rpc('customer_set_communication_preference_v263',{
      p_category:input.dataset.category,p_channel:input.dataset.channel,p_enabled:wanted
    });
    if(!isCurrent()||!input.isConnected)return;
    input.disabled=false;
    if(setError){input.checked=!wanted;syncMaster();say('That choice could not be saved, so it has been put back. Please try again.');return}
    syncMaster();say('Saved.');
  });
  if(master)master.onchange=async()=>{
    const wanted=master.checked;
    const before=[...document.querySelectorAll('.customerCommsToggle')].map(input=>[input,input.checked]);
    master.disabled=true;before.forEach(([input])=>{input.disabled=true;input.checked=wanted});
    say('Saving…');
    const {error:setError}=await sb.rpc('customer_set_all_communications_v263',{p_enabled:wanted});
    if(!isCurrent()||!master.isConnected)return;
    master.disabled=false;before.forEach(([input])=>{input.disabled=false});
    if(setError){
      master.checked=!wanted;before.forEach(([input,was])=>{input.checked=was});
      say('That change could not be saved, so your choices have been put back. Please try again.');return;
    }
    say(wanted?'All marketing messages are on.':'All marketing messages are off. Receipts, bookings and security messages still send.');
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
  host.innerHTML=`${requests.map(item=>`<div class="wallet-appt"><div><b>${esc(walletDate(item.preferred_at,true)||'Preferred time pending')}</b><p class="muted small" style="margin-top:3px">${esc(item.service_name||'Booking request')} · awaiting the business</p></div><span class="spacer"></span><span class="pill ${item.status==='waitlisted'?'new':'off'}">${esc(item.status==='waitlisted'?'Waitlisted':'Pending')}</span></div>`).join('')}
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
  const personaPromise=signedInUser?Promise.resolve(sb.rpc('get_my_personas')).catch(error=>({data:null,error})):Promise.resolve({data:null,error:null});
  const profilePromise=signedInUser?Promise.resolve(sb.rpc('customer_get_profile')).catch(error=>({data:null,error})):Promise.resolve({data:null,error:null});
  let biz;
  const portalLoadTimeout=12000,portalLoadController=new AbortController();
  const portalLoadTimer=setTimeout(()=>portalLoadController.abort(),portalLoadTimeout);
  try{biz=await publicGateway('public-booking',{method:'GET',query:`?slug=${encodeURIComponent(slug)}`,signal:portalLoadController.signal})}
  catch(error){
    if(isPortalCurrent()){
      const card=root.querySelector('.card');
      if(card){card.innerHTML=`<div class="empty"><div class="big">${CUI.icon('bookings',{size:30})}</div><h2>${error?.name==='AbortError'?'Booking page took too long':'Booking page could not load'}</h2><p class="muted small" style="margin-top:6px">Check your connection, then retry. Your account session has not been changed.</p><button class="btn" id="portalRetry" type="button" style="margin-top:14px">Retry booking page</button></div>`;const retry=$('portalRetry');if(retry)retry.onclick=()=>renderPortal(slug)}
    }
    return;
  }finally{clearTimeout(portalLoadTimer)}
  if(!isPortalCurrent())return;

  const bc=contrastSafeBrandColor(biz.brand_color);
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
  const middleStep=usesTables?'table':(staffChoice?'team':'');
  const steps=['service',middleStep,'time','details'].filter(Boolean);
  const stepMeta={service:{label:'Service'},table:{label:'Table'},team:{label:'Team'},time:{label:'Time'},details:{label:'Details'}};
  let selSvc=repeatService?.id||null;     // null = general reservation, or a validated public service uuid
  let serviceChosen=!!repeatService||!hasServices;
  let selTable=null;                     // reservation table type uuid (null = any/general)
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
     app.v183_bookable_staff() exactly so the page never offers someone the server will reject. */
  const staffForService=()=>bookableStaff.filter(member=>{
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
  const availabilityKey=()=>JSON.stringify({service:selSvc||'',staff:selStaff||''});
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
    const stepBody={service:serviceStep,table:tableStep,team:teamStep,time:timeStep,details:detailsStep};
    root.innerHTML=`<div class="portal customer-surface" style="--coral:${bc};--grad:linear-gradient(100deg,${bc},${bc})">
      <div class="head">${portalBackHrefV192?`<a class="btn ghost sm portal-back" href="${esc(portalBackHrefV192)}">${CUI.icon('back',{size:17})}<span>Back</span></a>`:''}<h1 style="font-size:2rem">${esc(biz.name)}</h1><p class="muted">Book with us — it takes 30 seconds.</p></div>
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
      </div>${legalLinks()}</div>`;
    const buildSummary=()=>{
      const el=$('pfSummary');if(!el)return;
      const s=svcObj();
      const rows=[['Service', s?esc(s.name):'General visit']];
      if(s)rows.push(['Duration & price',`${s.duration_min} min · ${esc(currency)} ${(s.price_cents/100).toFixed(2)}`]);
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
        data=await publicGateway('public-booking',{method:'GET',query:`?slug=${encodeURIComponent(slug)}&availability=1${selSvc?`&service=${encodeURIComponent(selSvc)}`:''}${selStaff?`&staff=${encodeURIComponent(selStaff)}`:''}&days=14`});
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
        $('perr').innerHTML=`<div class="err">${esc(error.message)}</div>`;
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
      catch(error){$('merr').innerHTML=`<div class="err">${esc(error.message)}</div>`;$('mfind').disabled=false;return}
      $('mfind').disabled=false;
      const when=data.starts_at||data.preferred_at;
      /* v286 (audit): this was the one time on the whole booking surface printed in the device's
         zone — toLocaleString() with no timeZone. A traveller, or a phone set to the wrong zone,
         read a different hour here than in the confirmation card and in Bookings, and could
         reschedule against a time that never existed. walletDate() is the surface's own SGT
         formatter, the same one every other date here already goes through. */
      $('mlist').innerHTML=`<div style="padding:10px 0"><b>${esc(walletDate(when,true))||'Time pending'}</b>
        <div class="muted small">${esc(data.service_name||'general visit')} · ${esc(data.status||'pending')}</div></div>
        ${data.can_change?`<label>New preferred time</label><input type="datetime-local" id="mdt">
        <div class="row" style="margin-top:10px"><button class="btn ghost sm" id="mcancel" onclick="mCancel()">Request cancellation</button>
        <button class="btn sm" id="mresched" onclick="mReschedule()">Request reschedule</button></div>`:'<p class="muted small">Changes are not available for this booking.</p>'}`;
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
  window.mCancel=async()=>{
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
    catch(error){manageChangeBusyV286(false);return toast(error.message)}
    manageChangeSettledV286(data);
  };
  window.mReschedule=async()=>{
    manageToken=($('mtoken')?.value||manageToken).trim();
    if(!manageToken) return toast('Enter your booking management code');
    const val=$('mdt')?.value;
    if(!val) return toast('Pick a new date & time first');
    const proposed=sgIso(val),key=JSON.stringify({kind:'reschedule',proposed,note:null});
    if(!changeAttempt||changeAttempt.key!==key)changeAttempt={key,id:crypto.randomUUID()};
    let data;
    manageChangeBusyV286(true);
    try{data=await publicGateway('manage-booking',{body:{action:'change',token:manageToken,submission_id:changeAttempt.id,kind:'reschedule',proposed,note:null}})}
    catch(error){manageChangeBusyV286(false);return toast(error.message)}
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

