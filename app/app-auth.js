/* GENERATED FILE — do not edit.
   The merchant sign-in, persona and invite screens of app/app.js, split by scripts/quality/split-app-bundle.mjs.
   Edit app/app.js and run: npm run bundle-stamp */
function renderPersonaResolutionUnavailable(){
  globalThis.document?.documentElement?.setAttribute('lang','en');
  root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="accountAccessTitle">
    <div class="logo" style="margin-bottom:6px">${brandWordmark()}</div>
    <h1 id="accountAccessTitle" style="font-size:1.5rem;margin:14px 0 6px">We couldn't load your account</h1>
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
    <h1 id="workspaceAccessTitle" style="font-size:1.5rem;margin:14px 0 6px">Workspace access unavailable</h1>
    <p class="muted" style="line-height:1.6">Your staff access is inactive or no longer assigned. Ask the workspace owner to reactivate your access before trying again.</p>
    <button class="btn ghost" id="workspaceAccessSignOut" style="width:100%;margin-top:18px">Sign out</button>
    ${accountDeletionCardHtml()}${legalLinks()}</section></main>`;
  const main=$('main');main.focus();
  CUI.announce('Workspace access is inactive or unavailable.',{assertive:true});
  $('workspaceAccessSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
  wireAccountDeletionButton();
}

function renderBusinessWorkspaceControl(control={}){
  const approval=control.approval||{},subscription=control.subscription||{},representative=control.representative||{};
  const approvalStatus=approval.status||'pending';
  if(approvalStatus==='pending'&&control._selfServeChecked!==true){
    root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" style="text-align:center"><div class="logo">${brandWordmark()}</div><h1 style="font-size:1.5rem;margin-top:18px">Checking payment status…</h1></section></main>`;
    sb.rpc('get_self_serve_checkout_v130',{p_business:control.business_id}).then(({data})=>{
      const onboarding=data?.onboarding;
      if(!onboarding||onboarding.status!=='payment_pending'){
        renderBusinessWorkspaceControl({...control,_selfServeChecked:true});return;
      }
      if(NestlyNativeBridge.isNative){renderNativeBusinessCompanion();return}
      root.innerHTML=`<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card" aria-labelledby="businessControlTitle"><div class="logo">${brandWordmark()}</div><h1 id="businessControlTitle" style="font-size:1.65rem;margin-top:18px">Payment confirmation pending</h1><p class="muted" style="line-height:1.6;margin-top:7px">This workspace is saved but locked. Complete secure payment through Stripe; Peekaa opens access only after a matching paid invoice is confirmed.</p><div class="card" style="margin-top:16px"><b>${esc(onboarding.business_name)}</b><p class="muted small" style="margin-top:5px">${esc(onboarding.cadence)} · up to ${Number(onboarding.customer_capacity).toLocaleString('en-SG')} customers · ${money(Number(onboarding.total_cents||0))}</p><p class="muted small" style="margin-top:5px">GST not charged</p></div><button class="btn" id="businessControlPay" style="width:100%;margin-top:18px">Complete secure payment</button><p class="muted small" id="businessControlPayStatus" role="status" aria-live="polite" style="margin-top:8px">Returning from Checkout does not unlock this workspace until Stripe confirms payment.</p><button class="btn ghost" id="businessControlRetry" style="width:100%;margin-top:10px">Check again</button><button class="btn ghost" id="businessControlSignOut" style="width:100%;margin-top:10px">Sign out</button>${accountDeletionCardHtml()}${legalLinks()}</section></main>`;
      $('businessControlPay').onclick=async()=>{
        const button=$('businessControlPay'),status=$('businessControlPayStatus');button.disabled=true;status.textContent='Opening secure Stripe Checkout…';
        const storageKey=`nestly-self-serve-checkout-${onboarding.business_id}`;let key=sessionStorage.getItem(storageKey);if(!key){key=crypto.randomUUID();sessionStorage.setItem(storageKey,key)}
        const requested=await sb.rpc('request_self_serve_checkout_v130',{p_business:onboarding.business_id,p_cadence:onboarding.cadence,p_customer_capacity:onboarding.customer_capacity,p_idempotency_key:key});
        if(requested.error||!requested.data?.command_id){button.disabled=false;status.textContent='We could not recover the saved checkout. Retry the same payment step.';return}
        const executed=await sb.functions.invoke('stripe-billing-command',{body:{command_id:requested.data.command_id}});
        if(executed.data?.redirect_url){sessionStorage.removeItem(storageKey);location.assign(executed.data.redirect_url);return}
        button.disabled=false;status.textContent='Stripe is still processing this payment. Check again after payment is confirmed.';
      };
      $('businessControlRetry').onclick=route;
      $('businessControlSignOut').onclick=async()=>{killChannels();await sb.auth.signOut();resetClientSessionState();location.hash='#/';route()};
      wireAccountDeletionButton();
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
    <div class="entry-choice-icon" style="margin-top:18px">${CUI.icon(paused?'info':'branch',{size:25})}</div>
    <h1 id="businessControlTitle" style="font-size:1.65rem;margin:14px 0 6px">${esc(title)}</h1>
    <p class="muted" style="line-height:1.6">${esc(message)}</p>
    ${representative.display_name||hotline?`<section class="workspace-control-contact" style="margin-top:16px"><b>Assigned representative</b><p class="muted small" style="margin-top:4px">${esc(representative.display_name||'Peekaa support')}</p>${hotline?`<a class="btn" href="tel:${esc(hotline)}" style="width:100%;margin-top:12px">${CUI.icon('till',{size:17})}<span>Call ${esc(hotline)}</span></a>`:''}</section>`:''}
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
      <section class="entry-choice" aria-labelledby="personaWorkspacesTitle"><span class="entry-choice-icon">${CUI.icon('branch',{size:25})}</span><div><h2 id="personaWorkspacesTitle">Business workspaces</h2><p class="muted">Choose an authorized workspace. Direct workspace links remain available.</p><div class="row" style="margin-top:12px">${staff.map(workspace=>`<a class="btn ghost sm" href="#/workspace/${encodeURIComponent(workspace.business_slug)}/dashboard">${esc(workspace.business_name||workspace.business_slug)}</a>`).join('')}</div></div></section>
      ${hasCustomer?`<a class="entry-choice" href="#/wallet"><span class="entry-choice-icon">${CUI.icon('customers',{size:25})}</span><div><h2>${esc(BRAND.customerLabel)}</h2><p class="muted">See your customer programmes, rewards, value, visits, bookings, and messages.</p></div><span class="inline-status" style="font-weight:700;color:var(--coral)">Open ${esc(BRAND.customerLabel)} ${CUI.icon('forward',{size:17})}</span></a>`:''}
    </div>
    <button class="btn ghost sm" id="personaChoiceSignOut" type="button" style="margin-top:18px">${CUI.icon('back',{size:17})}<span>Sign out</span></button>
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
    <section class="card" style="margin-top:16px;background:var(--sand);text-align:left"><span class="muted small">Company invite code</span><p class="staff-invite-code" style="font-size:1.15rem;margin-top:6px">${esc(normalized)}</p><p class="muted small" style="margin-top:8px;overflow-wrap:anywhere">Signed in as ${esc(S.user?.email||'Email unavailable')}</p></section>
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
    nav(`#/workspace/${encodeURIComponent(data.business_slug||slug)}/dashboard`);
  };
}

