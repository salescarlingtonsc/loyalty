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
    if(next?.status==='active'){nav(selfServeActivatedRouteV286(next.business_slug));return}
    const status=$('selfServePayStatus');
    if(status)status.textContent=attempts<15?'Stripe confirmation is still processing. Checking again…':'Stripe has not confirmed activation yet. Use Check payment again or contact Peekaa support if this continues.';
    if(attempts<15)setTimeout(poll,2000);
  };
  setTimeout(poll,1200);
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
      <section class="entry-choice" aria-labelledby="personaWorkspacesTitle"><span class="entry-choice-icon">${CUI.icon('branch',{size:24})}</span><div><h2 id="personaWorkspacesTitle">Business workspaces</h2><p class="muted">Choose an authorized workspace. Direct workspace links remain available.</p><div class="row" style="margin-top:12px">${staff.map(workspace=>`<a class="btn ghost sm" href="#/workspace/${encodeURIComponent(workspace.business_slug)}/dashboard">${esc(workspace.business_name||workspace.business_slug)}</a>`).join('')}</div></div></section>
      ${hasCustomer?`<a class="entry-choice" href="#/wallet"><span class="entry-choice-icon">${CUI.icon('customers',{size:24})}</span><div><h2>${esc(BRAND.customerLabel)}</h2><p class="muted">See your customer programmes, rewards, value, visits, bookings, and messages.</p></div><span class="inline-status" style="font-weight:700;color:var(--coral)">Open ${esc(BRAND.customerLabel)} ${CUI.icon('forward',{size:16})}</span></a>`:''}
    </div>
    <button class="btn ghost sm" id="personaChoiceSignOut" type="button" style="margin-top:18px">${CUI.icon('back',{size:16})}<span>Sign out</span></button>
    ${accountDeletionCardHtml()}${legalLinks()}</section></main>`;
  CUI.focusRoute($('main'),{enhanceContent:true});
  wireAccountDeletionButton();
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
    if(preview?.status&&preview.status!=='valid'){
      $('staffInviteAcceptStatus').innerHTML='<div class="err">This invite is not active. Ask the business owner for a new company invite link.</div>';
      $('staffInviteAcceptGo').disabled=false;return;
    }
    invalidatePersonaCacheV370(); // V370: accepting an invite creates a staff persona
    const {data,error}=await sb.rpc('accept_invite',{p_code:normalized});
    if(error){
      $('staffInviteAcceptStatus').innerHTML=`<div class="err">${esc(error.message||'This invite could not be accepted. It may be invalid, expired, revoked, already used, or restricted to another email.')}</div>`;
      $('staffInviteAcceptGo').disabled=false;return;
    }
    sessionStorage.removeItem(STAFF_INVITE_STORAGE_V151);
    S.biz=data;S.myModules=null;S.myModulePerms=null;S.myRole=null;S.staffWorkspaces=[];
    const slug=data?.slug||data?.business_slug||'';
    toast('Welcome to the team');
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
