/* GENERATED FILE — do not edit.
   The merchant sign-in, persona and invite screens of app/app.js, split by scripts/quality/split-app-bundle.mjs.
   Edit app/app.js and run: npm run bundle-stamp */
function renderPersonaResolutionUnavailable(){
  globalThis.document?.documentElement?.setAttribute('lang','en');
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="accountAccessTitle">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    <h1 id="accountAccessTitle" style="font-size:24px;margin:14px 0 6px">We couldn't load your account</h1>
    <p class="muted" style="line-height:1.6">Your account is still signed in. Retry to open the correct business or customer view.</p>
    <button class="btn" id="accountAccessRetry" style="width:100%;margin-top:18px">Retry</button>
    <button class="btn ghost" id="accountAccessSignOut" style="width:100%;margin-top:10px">Sign out</button>
    ${accountDeletionCardHtml()}${legalLinks()}</section></main>`;
  const main=$('main');main.focus();
  CUI.announce('Account access could not be loaded.',{assertive:true});
  $('accountAccessRetry').onclick=route;
  $('accountAccessSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
  wireAccountDeletionButton();
}

function renderWorkspaceAccessUnavailable(){
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="workspaceAccessTitle">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    <h1 id="workspaceAccessTitle" style="font-size:24px;margin:14px 0 6px">Workspace access unavailable</h1>
    <p class="muted" style="line-height:1.6">Your staff access is inactive or no longer assigned. Ask the workspace owner to reactivate your access before trying again.</p>
    <button class="btn ghost" id="workspaceAccessSignOut" style="width:100%;margin-top:18px">Sign out</button>
    ${accountDeletionCardHtml()}${legalLinks()}</section></main>`;
  const main=$('main');main.focus();
  CUI.announce('Workspace access is inactive or unavailable.',{assertive:true});
  $('workspaceAccessSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
  wireAccountDeletionButton();
}

/* V281 — the "pay now" button must always land in one of three DEFINED states: redirected to
   Stripe, a named recoverable message, or a named terminal message. It previously had a fourth,
   undefined one. stripe-billing-command answers HTTP 202 with status 'uncertain' when it cannot
   prove whether Stripe executed, and documents its own recovery in the same body:
   `recovery:'retry_same_command_id'` — re-invoking the SAME command id retrieves the Checkout
   session that was in fact created and returns its URL. The platform console has performed that
   replay since V156. Neither owner-facing self-service surface did: both fell through to a
   generic "still pending" line, leaving an owner who HAD a live Stripe session staring at a
   screen that told them to wait for a webhook that would never come, because they never paid.
   Both surfaces now run this one executor, so the two copies cannot drift again. */
const SELF_SERVE_CHECKOUT_STATUS_V281=Object.freeze({
  opening:'Opening secure Stripe Checkout…',
  request_failed:'We could not confirm the saved checkout request. Retry; the same request will be reused.',
  unreachable:'Stripe could not be reached. Retry to recover the same secure checkout.',
  pending:'Stripe has not returned a checkout page yet. Retry — the same secure checkout is reused, and nothing is charged twice.'
});
function selfServeCheckoutKeyV281(businessId){
  return `nestly-self-serve-checkout-${businessId}`;
}
async function runSelfServeCheckoutV281(onboarding){
  const storageKey=selfServeCheckoutKeyV281(onboarding.business_id);
  let idempotencyKey=sessionStorage.getItem(storageKey);
  if(!idempotencyKey){idempotencyKey=crypto.randomUUID();sessionStorage.setItem(storageKey,idempotencyKey)}
  const requested=await sb.rpc('request_self_serve_checkout_v130',{
    p_business:onboarding.business_id,p_cadence:onboarding.cadence,
    p_customer_capacity:onboarding.customer_capacity,p_idempotency_key:idempotencyKey
  });
  if(requested.error||!requested.data?.command_id)
    return {outcome:'request_failed',message:SELF_SERVE_CHECKOUT_STATUS_V281.request_failed};
  const commandId=requested.data.command_id;
  const executed=await sb.functions.invoke('stripe-billing-command',{body:{command_id:commandId}});
  if(executed.error)
    return {outcome:'unreachable',message:SELF_SERVE_CHECKOUT_STATUS_V281.unreachable};
  let result=executed.data||requested.data;
  /* Exactly one replay, and only of the same command id — the server holds a stable Stripe
     idempotency key for it, so this retrieves or replays the identical session and can never
     create a second one or a second charge. */
  if(!result?.redirect_url&&['uncertain','pending','processing'].includes(String(result?.status||''))){
    const recovered=await sb.functions.invoke('stripe-billing-command',{body:{command_id:commandId}});
    if(!recovered.error&&recovered.data)result=recovered.data;
  }
  if(result?.redirect_url){
    sessionStorage.removeItem(storageKey);
    return {outcome:'redirect',redirectUrl:result.redirect_url};
  }
  return {outcome:'pending',message:SELF_SERVE_CHECKOUT_STATUS_V281.pending};
}
async function driveSelfServeCheckoutV281(onboarding,statusNode,button){
  if(button)button.disabled=true;
  if(statusNode)statusNode.textContent=SELF_SERVE_CHECKOUT_STATUS_V281.opening;
  const outcome=await runSelfServeCheckoutV281(onboarding);
  if(outcome.outcome==='redirect'){location.assign(outcome.redirectUrl);return outcome}
  /* Every non-redirect outcome re-enables the button. A disabled button with a "pending"
     message is the stuck state this function exists to remove. */
  if(button)button.disabled=false;
  if(statusNode)statusNode.textContent=outcome.message;
  return outcome;
}
/* V286: ONE owner of the self-serve "payment confirmation pending" screen.
   Two drifted copies existed. renderOnboard's copy understood the contract Stripe actually
   returns to — `/business#/onboarding/payment?status=processing|canceled` (see
   supabase/functions/stripe-billing-command success_url/cancel_url) — and polled for verified
   activation. renderBusinessWorkspaceControl's copy did not read the status param at all.
   Only the SECOND was reachable: start_self_serve_business_v130 creates an ACTIVE owner staff
   row, so get_my_personas resolves a workspace and route() never falls through to renderOnboard.
   A paying owner returning from Stripe was therefore shown "Payment confirmation pending" under
   a "Complete secure payment" button — asked to pay a second time for the payment they had just
   made. The drifted duplicate is collapsed here the way V281 collapsed the checkout executors,
   and route() now resolves #/onboarding/payment BEFORE persona resolution so the return route
   reaches this renderer regardless of the staff row. */
const SELF_SERVE_RETURN_PROCESSING_V286=Object.freeze(['success','paid','processing','complete','completed']);
function selfServePaymentReturnStateV286(){
  const hashState=new URLSearchParams(String(location.hash||'').split('?')[1]||'').get('status');
  const searchState=new URLSearchParams(location.search||'').get('status');
  const state=String(hashState||searchState||'');
  return {
    canceled:state==='canceled'||state==='cancelled',
    processing:SELF_SERVE_RETURN_PROCESSING_V286.includes(state)
  };
}
/* V286 (with S5): a workspace that has just been paid for and opened lands on the first-run
   setup guide, not on an empty dashboard. Activation happens once, so this is once. */
function selfServeActivatedRouteV286(slug){
  return `#/workspace/${encodeURIComponent(String(slug||''))}/setup`;
}
/* nestly_v542 (owner, screenshot of this very screen: "i need a back button for firms to change
   from stripe payment to manual payment. because now not able to reverse the payment method").
   There was no way back, and a plain back LINK would have been worse than none: the only manual
   route in the product, request_self_serve_manual_application_v159, refuses any account already
   attached to a business — which every owner on this screen is — so the form it led to was
   guaranteed to 42501.
   This asks instead. business_request_manual_payment_v542 records a request and nothing else: no
   approval change, no workspace unlock, no invoice, no payment. The Super Admin still raises and
   verifies the invoice through the tools that already exist. The copy says exactly that, because
   an owner who believes they have switched and stops paying attention is the failure this screen
   cannot afford. */
function selfServeManualSwitchCardV542(onboarding){
  const businessId=String(onboarding?.business_id||'');
  if(!businessId)return '';
  return `<div class="card" style="margin-top:18px;text-align:left" data-self-serve-manual-v542>
    <b>Prefer bank transfer or another payment method?</b>
    <p class="muted small" style="margin-top:6px">Request manual payment and our team will assist you with the payment details. Your account will be activated once payment is verified.</p>
    <button class="btn ghost" id="selfServeManualAskV542" style="width:100%;margin-top:14px">Request manual payment</button>
    <p class="muted small" id="selfServeManualStatusV542" role="status" aria-live="polite" style="margin-top:8px"></p>
  </div>`;
}
function wireSelfServeManualSwitchV542(onboarding){
  const button=$('selfServeManualAskV542');
  if(!button)return;
  const status=$('selfServeManualStatusV542');
  const businessId=String(onboarding?.business_id||'');
  const settled=text=>{button.disabled=true;button.textContent='Manual payment requested';if(status)status.textContent=text};
  /* Show an existing request on arrival, so a returning owner is not invited to ask twice. */
  void sb.rpc('business_get_manual_payment_request_v542',{p_business:businessId}).then(({data,error})=>{
    if(error||!data||data.status!=='ok')return;
    if(data.request_status==='open')settled('We’ve received your request. Our team will assist you with the payment details. You can still pay online below if you prefer.');
  });
  /* One key per screen, so a double tap is the same request rather than a second one. The server
     is idempotent either way; this simply keeps the two in agreement. */
  const key=crypto.randomUUID();
  button.onclick=async()=>{
    button.disabled=true;
    if(status)status.textContent='Sending your request…';
    const {data,error}=await sb.rpc('business_request_manual_payment_v542',{
      p_business:businessId,p_idempotency_key:key,p_contact_phone:null,p_note:null});
    if(error){
      button.disabled=false;
      if(status)status.textContent=ownerErrorText(error);
      return;
    }
    if(data?.status==='ok')return settled('We’ve received your request. Our team will assist you with the payment details. You can still pay online below if you prefer.');
    button.disabled=false;
    if(status)status.textContent='That request could not be sent. Please try again.';
  };
}
function renderSelfServePaymentPendingV286(onboarding){
  const setupEpoch=++businessSetupRenderEpoch;
  if(NestlyNativeBridge.isNative){renderNativeBusinessCompanion();return}
  const {canceled,processing}=selfServePaymentReturnStateV286();
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="card" style="width:680px;max-width:100%" aria-labelledby="selfServePendingTitle"><div class="logo">${brandWordmark()}</div><h1 id="selfServePendingTitle" style="font-size:1.65rem;margin-top:18px">${canceled?'Complete secure payment':processing?'Setting up your Peekaa workspace…':'Payment confirmation pending'}</h1><p class="muted" style="margin-top:7px">${canceled?'Stripe Checkout was closed without payment. Your saved workspace remains locked and has not been charged.':processing?'Payment was returned from Stripe. Peekaa is waiting for the verified Stripe webhook before opening access.':'Peekaa has saved your business, but it remains locked until Stripe confirms the first paid invoice.'}</p>${businessSetupAccountHtml()}<div class="card" style="margin-top:18px"><b>${esc(onboarding.business_name)}</b><p class="muted small" style="margin-top:5px">${esc(onboarding.cadence==='annual'?'Annual':'Monthly')} · up to ${Number(onboarding.customer_capacity).toLocaleString('en-SG')} customers · ${money(Number(onboarding.total_cents||0))}</p><p class="muted small" style="margin-top:5px">GST not charged · Subscription fees are non-refundable after payment, except where required by law</p></div><button class="btn${processing?' ghost':''}" id="selfServePay" style="width:100%;margin-top:18px">${processing?'Open Stripe Checkout again':'Complete secure payment'}</button><p class="muted small" id="selfServePayStatus" role="status" aria-live="polite" style="margin-top:8px">${processing?'Checking verified activation status…':'Checkout success pages do not unlock access; provider-confirmed payment does.'}</p><button class="btn ghost" id="onboardRetry" style="width:100%;margin-top:10px">Check payment again</button>${selfServeManualSwitchCardV542(onboarding)}${accountDeletionCardHtml()}${legalLinks()}</section></main>`;
  wireBusinessSetupAccount();wireAccountDeletionButton();wireSelfServeManualSwitchV542(onboarding);
  $('selfServePay').onclick=()=>driveSelfServeCheckoutV281(onboarding,$('selfServePayStatus'),$('selfServePay'));
  $('onboardRetry').onclick=route;
  if(!processing)return;
  let attempts=0;
  const poll=async()=>{
    if(setupEpoch!==businessSetupRenderEpoch)return;
    attempts+=1;
    const current=await sb.rpc('get_self_serve_checkout_v130',{p_business:null});
    if(setupEpoch!==businessSetupRenderEpoch)return;
    const next=current.data?.onboarding;
    /* v770: the persona (45s) and control (120s) caches were taken at sign-in, BEFORE the webhook
       opened this workspace. Navigating on them lands the owner back on this very screen with no
       poll running (observed 2026-09-05, "cs cafe on": activated server-side at 07:40:49, page
       stuck). Drop them so the workspace route reads the opened state. */
    if(next?.status==='active'){invalidateWorkspaceBootstrapCachesV370();nav(selfServeActivatedRouteV286(next.business_slug));return}
    const status=$('selfServePayStatus');
    if(status)status.textContent=attempts<90?'Stripe confirmation is still processing. Checking again…':'Stripe has not confirmed activation yet. Use Check payment again or contact Peekaa support if this continues.';
    if(attempts<90)setTimeout(poll,2000);
  };
  setTimeout(poll,1200);
}
/* nestly_v620: a locked workspace whose lock is really "pay us" — the trial ran out, or a
   previously-paid subscription lapsed — gets a screen with a direct one-click path back to
   Stripe Checkout, instead of the generic "contact your representative" copy below. That copy
   is right for a still-pending approval or a paused-for-some-other-reason subscription; it is
   wrong for a lock the owner can clear themselves right now. get_business_entitlement_v620 is
   callable by any staff of the business even while locked, so any teammate opening a locked
   workspace resolves the same authoritative operational_state — this never guesses from the
   control payload's own paused/rejected flags, which predate v620 and do not distinguish
   trial_expired or payment_lapsed from the other lock reasons. */
function renderLockedWorkspacePaymentV620(control,entitlement){
  const trialExpired=entitlement.operational_state==='trial_expired';
  const headline=trialExpired?'Your trial has ended':'Your subscription payment has lapsed';
  const reason=String(entitlement.restriction_reason||'').trim();
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="workspaceLockedPaymentTitle">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    <div class="entry-choice-icon" style="margin-top:18px">${CUI.icon('info',{size:24})}</div>
    <h1 id="workspaceLockedPaymentTitle" style="font-size:1.65rem;margin:14px 0 6px">${esc(headline)}</h1>
    ${reason?`<p class="muted" style="line-height:1.6">${esc(reason)}</p>`:''}
    <div id="workspaceLockedPaymentError"></div>
    <button class="btn" id="workspaceLockedPaymentGo" style="width:100%;margin-top:16px">Continue to secure payment</button>
    <button class="btn ghost" id="workspaceLockedPaymentSignOut" style="width:100%;margin-top:10px">Sign out</button>
    ${accountDeletionCardHtml()}${legalLinks()}</section></main>`;
  $('main').focus();
  CUI.announce(headline+'.',{assertive:true});
  wireAccountDeletionButton();
  $('workspaceLockedPaymentSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
  $('workspaceLockedPaymentGo').onclick=async()=>{
    const button=$('workspaceLockedPaymentGo'),errorHost=$('workspaceLockedPaymentError');
    button.disabled=true;errorHost.innerHTML='';
    const businessId=String(control.business_id||'');
    /* Mirrors the Settings billing card's execute path (loadBillingConfig) — same idempotency
       attempt shape and the same sessionStorage slot key, so a retry here and a retry from
       Settings for the same business would recover the same in-flight command rather than
       racing two different ones. */
    const {data:billing,error:billingError}=await sb.rpc('get_business_billing_v125',{p_business:businessId});
    if(billingError||!billing){
      button.disabled=false;
      errorHost.innerHTML='<div class="err">Billing details could not load. Try again.</div>';
      return;
    }
    /* W3B/F096: this button used to hardcode annual, so a MONTHLY business whose payment lapsed
       was sent to a Stripe Checkout for the annual price with no cadence control on the screen to
       correct it. The business's own provider-confirmed cadence lives in billing.terms.cadence
       (billing_subscription_terms_v124.cadence, which a lapse never clears), and it is already
       being fetched here for `capacity`. Same resolution as loadBillingConfig()'s
       `initialCadence`: use the stored cadence when the payload still offers a plan for it, and
       fall back to annual only when there is no prior cadence to honour. */
    const plansV620=Array.isArray(billing.plans)?billing.plans:[];
    const byCadenceV620=Object.fromEntries(plansV620.map(plan=>[plan.cadence,plan]));
    const storedCadenceV620=String(billing.terms?.cadence||'');
    const cadence=(plansV620.length?byCadenceV620[storedCadenceV620]:storedCadenceV620==='annual'||storedCadenceV620==='monthly')
      ?storedCadenceV620:'annual';
    const capacity=Math.max(1000,Math.ceil((Number(billing.current_customer_count)||0)/1000)*1000,Number(billing.terms?.customer_capacity)||0);
    const billingAttemptSlot=`nestly:v124:billing-command:${businessId}`;
    const readBillingAttempt=()=>{try{return JSON.parse(sessionStorage.getItem(billingAttemptSlot)||'null')}catch{return null}};
    const writeBillingAttempt=attempt=>{try{sessionStorage.setItem(billingAttemptSlot,JSON.stringify(attempt))}catch{}};
    const clearBillingAttempt=key=>{try{const current=readBillingAttempt();if(!current||current.key===key)sessionStorage.removeItem(billingAttemptSlot)}catch{}};
    const fingerprint=JSON.stringify({type:'create_checkout',cadence,capacity});
    let attempt=readBillingAttempt();
    if(!attempt||attempt.fingerprint!==fingerprint){attempt={fingerprint,key:crypto.randomUUID(),command_id:null};writeBillingAttempt(attempt)}
    let requested=attempt.command_id?{command_id:attempt.command_id}:null,requestError=null;
    if(!requested){
      const response=await sb.rpc('request_billing_command_v124',{
        p_business:businessId,p_command_type:'create_checkout',p_cadence:cadence,
        p_customer_capacity:capacity,p_idempotency_key:attempt.key
      });
      requested=response.data;requestError=response.error;
    }
    if(requestError||!requested?.command_id){
      button.disabled=false;
      errorHost.innerHTML='<div class="err">Peekaa could not confirm whether the billing request was saved. Try again; the exact request will be reused.</div>';
      return;
    }
    attempt.command_id=requested.command_id;writeBillingAttempt(attempt);
    const executed=await sb.functions.invoke('stripe-billing-command',{body:{command_id:attempt.command_id}});
    if(executed.error){
      button.disabled=false;
      errorHost.innerHTML='<div class="err">Peekaa could not confirm Stripe’s result. Try again to recover the exact provider request.</div>';
      return;
    }
    const result=executed.data||requested;
    if(result.redirect_url){clearBillingAttempt(attempt.key);location.assign(result.redirect_url);return}
    if(['failed','canceled'].includes(result.status)){
      clearBillingAttempt(attempt.key);
      button.disabled=false;
      errorHost.innerHTML='<div class="err">Stripe did not complete this request. Try again.</div>';
    }else if(result.status==='uncertain'){
      button.disabled=false;
      errorHost.innerHTML='<div class="err">Stripe still needs payment confirmation. Try again; Peekaa will recover the exact request.</div>';
    }else{
      clearBillingAttempt(attempt.key);
      button.disabled=false;
      errorHost.innerHTML='<div class="err">Stripe did not return a checkout link. Try again.</div>';
    }
  };
}
function renderBusinessWorkspaceControl(control={}){
  const approval=control.approval||{},subscription=control.subscription||{},representative=control.representative||{};
  const approvalStatus=approval.status||'pending';
  if(approvalStatus==='pending'&&control._selfServeChecked!==true){
    root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" style="text-align:center"><div class="logo">${brandWordmark()}</div><h1 style="font-size:24px;margin-top:18px">Checking payment status…</h1></section></main>`;
    sb.rpc('get_self_serve_checkout_v130',{p_business:control.business_id}).then(({data})=>{
      const onboarding=data?.onboarding;
      if(!onboarding||onboarding.status!=='payment_pending'){
        renderBusinessWorkspaceControl({...control,_selfServeChecked:true});return;
      }
      /* V286: one owner for this state. This branch used to carry its own copy of the screen,
         blind to the ?status= the Stripe return lands with. */
      renderSelfServePaymentPendingV286(onboarding);
    });
    return;
  }
  if(control._entitlementCheckedV620!==true){
    root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" style="text-align:center"><div class="logo">${brandWordmark()}</div><h1 style="font-size:24px;margin-top:18px">Checking account status…</h1></section></main>`;
    sb.rpc('get_business_entitlement_v620',{p_business:control.business_id}).then(({data,error})=>{
      renderBusinessWorkspaceControl({...control,_entitlementCheckedV620:true,_entitlementV620:(!error&&data)?data:null});
    });
    return;
  }
  const entitlementStateV620=String(control._entitlementV620?.operational_state||'');
  if(entitlementStateV620==='trial_expired'||entitlementStateV620==='payment_lapsed'){
    return renderLockedWorkspacePaymentV620(control,control._entitlementV620);
  }
  const paused=subscription.workspace_paused===true;
  const rejected=approvalStatus==='rejected';
  const title=paused?'Business access paused':rejected?'Application not approved':'Approval pending';
  const message=paused
    ?`Payment is ${Number(subscription.overdue_day||14)} days overdue. Business-owner access is paused until provider payment is confirmed.`
    :rejected
      ?'This business application was not approved. Contact your assigned Peekaa representative if the information should be reviewed.'
      :'Your business application has been received. A Peekaa super admin must approve it before any business information or functions are available.';
  const rawPhone=String(representative.hotline_phone||'').replace(/[^\d+]/g,'');
  const phoneDigits=rawPhone.replace(/\D/g,'');
  const hotline=/^\+?\d{8,15}$/.test(rawPhone)
    ?(rawPhone.startsWith('+')?rawPhone:phoneDigits.startsWith('65')?`+${phoneDigits}`:`+65${phoneDigits}`)
    :'';
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="businessControlTitle">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    <div class="entry-choice-icon" style="margin-top:18px">${CUI.icon(paused?'info':'branch',{size:24})}</div>
    <h1 id="businessControlTitle" style="font-size:1.65rem;margin:14px 0 6px">${esc(title)}</h1>
    <p class="muted" style="line-height:1.6">${esc(message)}</p>
    ${representative.display_name||hotline?`<section class="workspace-control-contact" style="margin-top:16px"><b>Assigned representative</b><p class="muted small" style="margin-top:4px">${esc(representative.display_name||'Peekaa support')}</p>${hotline?`<a class="btn" href="tel:${esc(hotline)}" style="width:100%;margin-top:12px">${CUI.icon('till',{size:16})}<span>Call ${esc(hotline)}</span></a>`:''}</section>`:''}
    <button class="btn ghost" id="businessControlRetry" style="width:100%;margin-top:12px">Check again</button>
    ${S.hasCustomerPersona?'<a class="btn ghost" href="#/wallet" style="width:100%;margin-top:10px">Open customer view</a>':''}
    <button class="btn ghost" id="businessControlSignOut" style="width:100%;margin-top:10px">Sign out</button>
    ${accountDeletionCardHtml()}${legalLinks()}</section></main>`;
  $('main').focus();
  CUI.announce(title+'.',{assertive:true});
  $('businessControlRetry').onclick=route;
  $('businessControlSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
  wireAccountDeletionButton();
}

/* ---------- auth ---------- */
function renderPersonaChoice(personas,{includeCustomer=true}={}){
  const staff=sortStaffWorkspaces(personas?.staff);
  const hasCustomer=includeCustomer&&((personas?.customer||[]).length>0||personas?.registered_customer_profile===true);
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="card entry-choice-card" aria-labelledby="personaChoiceTitle">
    <div class="logo">${brandWordmark()}</div>
    <h1 id="personaChoiceTitle" style="font-size:clamp(1.8rem,5vw,2.5rem);margin-top:18px">Where would you like to go?</h1>
    <p class="muted" style="margin-top:7px;line-height:1.55">${hasCustomer?'This account has business and customer access.':'This account has more than one business workspace.'} Choose a destination for this visit.</p>
    <div class="entry-choice-grid">
      <section class="entry-choice" aria-labelledby="personaWorkspacesTitle"><span class="entry-choice-icon">${CUI.icon('branch',{size:24})}</span><div><h2 id="personaWorkspacesTitle">Business workspaces</h2><p class="muted">Choose an authorized workspace. Direct workspace links remain available.</p><div class="row" style="margin-top:12px">${staff.map(workspace=>`<a class="btn ghost" href="#/workspace/${encodeURIComponent(workspace.business_slug)}/dashboard">${esc(workspace.business_name||workspace.business_slug)}</a>`).join('')}</div></div></section>
      ${hasCustomer?`<a class="entry-choice" href="#/wallet"><span class="entry-choice-icon">${CUI.icon('customers',{size:24})}</span><div><h2>${esc(BRAND.customerLabel)}</h2><p class="muted">See your customer programmes, rewards, value, visits, bookings, and messages.</p></div><span class="inline-status" style="font-weight:700;color:var(--coral)">Open ${esc(BRAND.customerLabel)} ${CUI.icon('forward',{size:16})}</span></a>`:''}
    </div>
    <button class="btn ghost sm" id="personaChoiceSignOut" type="button" style="margin-top:18px">${CUI.icon('back',{size:16})}<span>Sign out</span></button>
    ${/* nestly_v593 (owner, photo 1: the whole Account & privacy block boxed — "can i not show
         this in this page? hide it inside account and privacy"). Choosing a destination is not
         the moment to read about closing an account, and the block was taller than the three
         workspace buttons this page exists for. What is removed is the BLOCK, not the ROUTE: the
         v131 store-readiness suite records an ⚖️ App Store 5.1.1(v) constraint that every
         signed-in surface must let a person START closing their account in the app, and this
         screen is signed in with no workspace behind it yet. So it becomes the same one small
         button Settings now uses, revealing the same card on demand. */''}
    ${accountPrivacyFooterHtmlV593()}${legalLinks()}</section></main>`;
  CUI.focusRoute($('main'),{enhanceContent:true});
  wireAccountPrivacyFooterV593();
  $('personaChoiceSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
}

function renderBusinessStaffInviteAcceptV151(code){
  const normalized=rememberBusinessStaffInviteV151(code);
  if(!normalized)return renderStaffInviteAuthV151('in','');
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="staffInviteAcceptTitle">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    <h1 id="staffInviteAcceptTitle" style="margin:14px 0 2px">Join business workspace</h1>
    <p class="muted small" style="margin-top:6px">Peekaa will validate this invite on the server. The company, role, module access, expiry, and reuse rules come from the invitation record.</p>
    <section class="card" style="margin-top:16px;background:var(--sand);text-align:left"><span class="muted small">Company invite code</span><p class="staff-invite-code" style="font-size:18px;margin-top:6px">${esc(normalized)}</p><p class="muted small" style="margin-top:8px;overflow-wrap:anywhere">Signed in as ${esc(S.user?.email||'Email unavailable')}</p></section>
    <div id="staffInviteAcceptPreviewV151" role="status" aria-live="polite" style="margin-top:10px">${staffInvitePreviewMarkupV151(null)}</div>
    <div id="staffInviteAcceptStatus" role="alert" aria-live="assertive"></div>
    <button class="btn" id="staffInviteAcceptGo" style="width:100%;margin-top:18px">Join business</button>
    <button class="btn ghost" id="staffInviteAcceptSignOut" style="width:100%;margin-top:10px">Use a different account</button>
    ${legalLinks()}</section></main>`;
  CUI.focusRoute($('main'),{enhanceContent:true});
  previewStaffInviteV151(normalized,'staffInviteAcceptPreviewV151');
  $('staffInviteAcceptGo').onclick=async()=>{
    $('staffInviteAcceptGo').disabled=true;
    $('staffInviteAcceptStatus').innerHTML='<p class="muted small" style="margin-top:10px">Checking invite and creating membership…</p>';
    const preview=await previewStaffInviteV151(normalized,'staffInviteAcceptPreviewV151');
    /* nestly_v588 (owner: "even using the reference code to sign up as staff, during sign up
       process - it is in a mess", pre-go-live 2026-08-29). accept_invite now replays correctly
       for the same user, and preview_staff_invite can answer 'awaiting_approval' for a code that
       already parked someone pending owner approval — both must be let through to the RPC, which
       is the real authority, instead of being refused here on the client. */
    if(preview?.status&&preview.status!=='valid'&&preview.status!=='awaiting_approval'){
      $('staffInviteAcceptStatus').innerHTML='<div class="err">This invite is not active. Ask the business owner for a new company invite link.</div>';
      $('staffInviteAcceptGo').disabled=false;return;
    }
    invalidatePersonaCacheV370(); // V370: accepting an invite creates a staff persona
    const {data,error}=await sb.rpc('accept_invite',{p_code:normalized});
    if(error){
      $('staffInviteAcceptStatus').innerHTML=`<div class="err">${esc(error.message||'This invite could not be accepted. It may be invalid, expired, revoked, already used, or restricted to another email.')}</div>`;
      $('staffInviteAcceptGo').disabled=false;return;
    }
    /* nestly_v588: the old code did `S.biz=data`, corrupting the business object with
       accept_invite's own {status,business_id,business_slug,business_name,message} payload, and
       toasted "Welcome to the team" even when the server had just parked the caller
       awaiting_approval. Never assign S.biz here — the workspace router re-derives it, and the
       v569 "Waiting for approval" card already handles a pending persona correctly. */
    sessionStorage.removeItem(STAFF_INVITE_STORAGE_V151);
    S.myModules=null;S.myModulePerms=null;S.myRole=null;S.staffWorkspaces=[];
    const slug=data?.business_slug||'';
    toast(data?.status==='approved'?'Welcome back — opening the workspace':(data?.message||'Joined — waiting for the owner to approve you'));
    if(slug)nav(`#/workspace/${encodeURIComponent(slug)}/dashboard`);else nav('#/dashboard');
  };
  $('staffInviteAcceptSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();renderStaffInviteAuthV151('in',normalized)};
}
async function renderApprovedBusinessActivation(inviteToken,isCurrent=()=>true){
  let invitation;
  try{invitation=await publicGateway('public-business-application',{method:'GET',query:`?invite=${encodeURIComponent(inviteToken)}`})}
  catch{
    const locale=businessApplicationLanguage(),t=key=>businessApplicationCopy(locale,key);
    globalThis.document?.documentElement?.setAttribute('lang',locale);
    root.innerHTML=`<div class="center-wrap"><div class="auth-card card"><h2>${esc(t('invitationUnavailable'))}</h2><p class="muted" style="margin-top:7px">${esc(t('invitationUnavailableIntro'))}</p><button class="btn ghost" id="invalidInviteOut" style="width:100%;margin-top:18px">${esc(t('signOut'))}</button>${legalLinks(locale)}</div></div>`;
    $('invalidInviteOut').onclick=async()=>{await sb.auth.signOut();history.replaceState(null,'','/business');route()};return;
  }
  if(!isCurrent())return;
  const locale=WORKSPACE_LOCALES_V97.includes(invitation.preferred_locale)?invitation.preferred_locale:'en',t=key=>businessApplicationCopy(locale,key);
  globalThis.document?.documentElement?.setAttribute('lang',locale);
  const base=String(invitation.business_name||'business').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'').slice(0,60)||'business';
  root.innerHTML=`<div class="center-wrap"><div class="auth-card card"><div class="logo">${brandWordmark()}</div><h2 style="margin-top:18px">${esc(t('createWorkspace'))}: ${esc(invitation.business_name)}</h2>
    <p class="muted small" style="margin-top:6px">${esc(t('finalStep'))}</p>
    <label for="approvedBusinessSlug">${esc(t('workspaceAddress'))}</label><div class="row"><span class="muted">peekaa.asia/business/</span><input id="approvedBusinessSlug" value="${esc(base)}"></div>
    <div id="approvedActivationError"></div><button class="btn" id="approvedActivationSubmit" style="width:100%;margin-top:18px">${esc(t('createApprovedWorkspace'))}</button>${legalLinks(locale)}</div></div>`;
  $('approvedActivationSubmit').onclick=async()=>{
    const slug=$('approvedBusinessSlug').value.trim().toLowerCase();
    $('approvedActivationSubmit').disabled=true;
    const activationKey=sessionStorage.getItem(`nestly-activation-${inviteToken}`)||crypto.randomUUID();
    sessionStorage.setItem(`nestly-activation-${inviteToken}`,activationKey);
    const {data,error}=await sb.rpc('activate_approved_business_application_v95',{
      p_invitation_token:inviteToken,p_business_slug:slug,p_idempotency_key:activationKey
    });
    if(error||data?.workspace_created!==true){
      $('approvedActivationError').innerHTML=`<div class="err">${esc(t('workspaceCreateError'))}</div>`;
      $('approvedActivationSubmit').disabled=false;return;
    }
    sessionStorage.removeItem(`nestly-activation-${inviteToken}`);
    history.replaceState(null,'','/business');
    /* V286: a workspace opened by an admin after manual payment lands on the first-run guide,
       the same as the Stripe self-serve path. */
    nav(selfServeActivatedRouteV286(data.business_slug||slug));
  };
}

/* V593 (owner, photo 1 + written instruction: "shift the entire account & privacy module into
   settings — put it at the bottom of the page just a small button, not so huge (so i dont see
   account & privacy in the drop down)"). Closing an account is a once-ever action, so inside the
   workspace it gets a once-ever affordance: one small ghost button at the foot of Settings that
   reveals the SAME accountDeletionCardHtml() card. No second copy of the copy, no second route —
   the card and its status loader are unchanged, only where they are reached from. */
function accountPrivacyFooterHtmlV593(){
  return `<div class="settings-account-privacy-v593" style="margin-top:22px;padding-top:16px;border-top:1px solid var(--line)">
    <div class="row" style="align-items:center;gap:10px;flex-wrap:wrap">
      <span class="muted small">Account &amp; privacy</span>
      <span class="spacer"></span>
      <button type="button" class="btn ghost sm" id="accountPrivacyToggleV593" aria-expanded="false" aria-controls="accountPrivacyPanelV593">Close account or ask what data is held</button>
    </div>
    <div id="accountPrivacyPanelV593" hidden></div>
  </div>`;
}

/* Renders the card only when the owner asks for it, then wires its status loader exactly as every
   other host of the card does. Deferring the render also defers the RPC — a Settings visit that
   never opens this panel makes no account-deletion lookup at all. */
function wireAccountPrivacyFooterV593(){
  const toggle=$('accountPrivacyToggleV593'),panel=$('accountPrivacyPanelV593');
  if(!toggle||!panel)return;
  toggle.onclick=()=>{
    const open=panel.hidden;
    panel.hidden=!open;
    toggle.setAttribute('aria-expanded',String(open));
    if(open&&!panel.dataset.filledV593){
      panel.innerHTML=accountDeletionCardHtml();
      panel.dataset.filledV593='1';
      wireAccountDeletionButton();
    }
  };
}

/* ---------- onboarding ---------- */
let businessSetupRenderEpoch=0;
function businessSetupAccountHtml(signOutId='out'){
  const email=String(S.user?.email||'Email unavailable');
  return `<div class="business-session-context" aria-label="Current business account"><div><span>Signed in as</span><strong>${esc(email)}</strong></div><button class="btn ghost sm" type="button" id="${esc(signOutId)}">Sign out</button></div>`;
}
function wireBusinessSetupAccount(signOutId='out'){
  const button=$(signOutId);if(!button)return;
  button.onclick=async()=>{
    ++businessSetupRenderEpoch;killChannels();
    await sb.auth.signOut({scope:'local'});
    resetClientSessionState();location.hash='#/';renderAuth('in');
  };
}
