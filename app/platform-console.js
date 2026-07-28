(function platformConsoleFactory(globalObject) {
  'use strict';

  const routes = Object.freeze([
    {key:'overview',label:'Overview',shortLabel:'Overview',hash:'#/platform',icon:'home'},
    {key:'onboarding',label:'Onboarding',shortLabel:'Onboard',hash:'#/platform/onboarding',icon:'setup'},
    {key:'firms',label:'Firms',shortLabel:'Firms',hash:'#/platform/firms',icon:'branch'},
    {key:'reports',label:'Reports',shortLabel:'Reports',hash:'#/platform/reports',icon:'reports'},
    {key:'billing',label:'Billing',shortLabel:'Billing',hash:'#/platform/billing',icon:'reports'},
    {key:'commissions',label:'Commission payable',shortLabel:'Commission',hash:'#/platform/commissions',icon:'staff'},
    {key:'sectors',label:'Sector modules',shortLabel:'Sectors',hash:'#/platform/sectors',icon:'packages'},
    {key:'automation',label:'Automation',shortLabel:'Automate',hash:'#/platform/automation',icon:'retention'},
    {key:'access',label:'Platform access',shortLabel:'Access',hash:'#/platform/access',icon:'staff',superAdminOnly:true}
  ]);
  const platformModuleKeys=Object.freeze([
    'overview','onboarding','firms','reports','billing','commissions','sectors','automation'
  ]);
  const platformModuleLabels=Object.freeze({
    overview:'Overview',onboarding:'Onboarding',firms:'Firms',reports:'Reports',
    billing:'Billing',commissions:'Commission payable',sectors:'Sector modules',
    automation:'Automation'
  });
  const prospectStages = Object.freeze([
    ['new_lead','New Lead'],['appt_set','Appointment Set'],
    ['npu_1','NPU 1'],['npu_2','NPU 2'],['npu_3','NPU 3'],['npu_4','NPU 4'],['npu_5','NPU 5'],['npu_6','NPU 6'],
    ['call_back','Call Back'],['reschedule','Reschedule'],['meeting_sent','Meeting Link Sent / Calendar Set'],
    ['pending_decision','Pending Decision'],['client','Client / Deal Won'],['account_created','Account Created'],
    ['onboarding','Onboarding in Progress'],['activated','Activated'],['lost','Lost']
  ].map(([key,label])=>Object.freeze({key,label})));
  const operationalLanes = Object.freeze([
    Object.freeze({key:'inbox',label:'New & unassigned',description:'New leads and records that need triage',
      stages:Object.freeze(['unmapped','new_lead'])}),
    Object.freeze({key:'contacting',label:'Contact & meeting',description:'Outreach, callbacks and scheduled conversations',
      stages:Object.freeze(['appt_set','npu_1','npu_2','npu_3','npu_4','npu_5','npu_6','call_back','reschedule','meeting_sent'])}),
    Object.freeze({key:'decision',label:'Decision',description:'Qualified firms considering the proposal',
      stages:Object.freeze(['pending_decision'])}),
    Object.freeze({key:'case_won',label:'Case won',description:'Signed, website-signup and onboarded firms',
      stages:Object.freeze(['client','account_created','onboarding','activated'])}),
    Object.freeze({key:'closed',label:'Closed',description:'Opportunities closed without activation',
      stages:Object.freeze(['lost'])})
  ]);
  const sectorModuleCatalog = Object.freeze([
    ['dashboard','Dashboard','Essentials'],['till','Quick earn','Essentials'],
    ['clients','Customers','Essentials'],['appointments','Appointments','Customer operations'],
    ['sales','Sales','Customer operations'],['services','Services','Customer operations'],
    ['bookings','Bookings','Customer operations'],['waitlist','Waitlist','Customer operations'],
    ['packages','Packages','Commerce'],
    ['loyalty','Loyalty','Growth'],['retention','Retention','Growth'],
    ['referrals','Referrals','Growth'],['memberships','Memberships','Growth'],
    ['giftcards','Gift cards','Growth'],['reports','Reports','Insights'],
    ['staffperf','Staff performance','Insights'],['dailyreport','Daily report','Insights'],
    ['pnl','P&L','Finance'],['expenses','Expenses','Finance']
  ].map(([key,label,group])=>Object.freeze({key,label,group})));
  const sectorModuleByKey = new Map(sectorModuleCatalog.map(module=>[module.key,module]));
  const lostReasons = Object.freeze([
    'no_response','not_interested','no_budget','timing','chose_competitor',
    'missing_required_feature','procurement_security_blocker','price',
    'internal_priority_changed','business_ceased','duplicate','bad_fit','other'
  ]);
  const CRM=globalObject.NestlyPlatformCRMUtils||null;
  const priorityRank=Object.freeze({urgent:4,high:3,normal:2,low:1});
  const stageGateDefinitions=Object.freeze({
    new_lead:['Company name or registration number','Lead source'],
    appt_set:['Primary contact','Valid email or phone','Appointment date and owner','Next action'],
    npu_1:['Attempt channel and timestamp','Next attempt or terminal disposition'],
    npu_2:['Attempt channel and timestamp','Next attempt or terminal disposition'],
    npu_3:['Attempt channel and timestamp','Next attempt or terminal disposition'],
    npu_4:['Attempt channel and timestamp','Next attempt or terminal disposition'],
    npu_5:['Attempt channel and timestamp','Next attempt or terminal disposition'],
    npu_6:['Attempt channel and timestamp','Next attempt or terminal disposition'],
    call_back:['Callback date and assigned person','Reason or context'],
    reschedule:['Previous meeting reference','New time and reschedule reason'],
    meeting_sent:['Confirmed meeting time','Channel, location or meeting URL','Attendees'],
    pending_decision:['Qualification summary','Decision maker','Decision date or follow-up','Objection, proposed value and next action'],
    client:['Accepted product, seats, billing cycle, value and currency','Owner email','Onboarding owner and target go-live'],
    account_created:['Successful server-side conversion','Linked workspace and owner invitation'],
    onboarding:['Evidence checklist and responsible owner','Target go-live and incomplete mandatory work'],
    activated:['Accepted owner access','Valid subscription','Required configuration and first-value evidence','Go-live approval'],
    lost:['Structured loss reason','Recontact decision']
  });
  let renderGeneration = 0;
  let activeContext = null;
  let readOnlyObserver = null;
  const platformWriteSelector=[
    '#platformNewProspect','#platformImportProspects','#platformScopedNewProspect',
    '[data-move]','[data-move-select]','[data-edit-prospect]','[data-assign-prospect]','[data-scoped-assign]',
    '[data-add-note]','[data-add-npu]','[data-add-activity]','[data-add-task]',
    '[data-add-contact]','[data-edit-contact-profile]','[data-edit-company-profile]',
    '[data-edit-qualification]','[data-edit-commercial-detail]','[data-edit-conversion-config]',
    '[data-refresh-quality]','[data-upload-document]','[data-lost]','[data-convert]',
    '[data-create-account]','[data-complete-task]','[data-onboarding-start]',
    '[data-onboarding-refresh]','[data-onboarding-reissue]','[data-onboarding-block]',
    '[data-onboarding-unblock]','[data-onboarding-activate]','[data-onboarding-evidence]',
    '[data-onboarding-waive]','[data-onboarding-item-block]','[data-onboarding-item-unblock]',
    '#platformNewBundle','[data-edit-sector]','[data-assign-firm]','[data-override-firm]',
    '[data-business-approval]','[data-module-control]','[data-catalogue-intelligence]',
    '#platformNewBillingPrice','[data-billing-command]',
    '#platformNewConsultant','#platformAttributeConsultant','#platformNewPolicy',
    '#platformNewPayout','[data-edit-consultant]','[data-forfeit-consultant]',
    '[data-approve-accrual]','[data-add-payout-line]','[data-approve-payout]',
    '[data-record-payout]','[data-automation-write]'
  ].join(',');

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, character => ({
      '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
    }[character]));
  }

  const idempotencyKey = () => globalObject.crypto?.randomUUID?.()
    || `platform-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const asObject = value => value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  function normalizePlatformAccess(payload) {
    const value=asObject(payload),role=String(value.role||'');
    if(!['super_admin','admin','sales_staff'].includes(role))return null;
    const modulePerms=asObject(value.module_perms);
    return Object.freeze({
      role,modulePerms,
      scope:value.scope==='own_created_or_assigned'?'own_created_or_assigned':'all'
    });
  }
  function modulePermission(access,moduleKey) {
    if(!access)return'off';
    if(access.role==='super_admin')return'rw';
    const value=access.modulePerms[moduleKey]??access.modulePerms['*'];
    return value==='rw'?'rw':value==='r'?'r':'off';
  }
  function stripPlatformWriteControls(host) {
    if(!host?.querySelectorAll)return;
    host.querySelectorAll(platformWriteSelector).forEach(control=>control.remove());
  }
  function installReadOnlyGuard(context) {
    readOnlyObserver?.disconnect();readOnlyObserver=null;
    if(context.canWrite)return;
    stripPlatformWriteControls(context.root);
    if(typeof MutationObserver==='undefined')return;
    readOnlyObserver=new MutationObserver(records=>{
      records.forEach(record=>record.addedNodes.forEach(node=>{
        if(node.nodeType!==1)return;
        if(node.matches?.(platformWriteSelector))node.remove();
        else stripPlatformWriteControls(node);
      }));
    });
    readOnlyObserver.observe(document.body,{childList:true,subtree:true});
  }
  const canAccessModule=(access,moduleKey)=>modulePermission(access,moduleKey)!=='off';
  const canWriteModule=(access,moduleKey)=>modulePermission(access,moduleKey)==='rw';
  const superAdminOnly=(isSuperAdmin,content)=>isSuperAdmin?content:'';
  const reportSectionAccess=access=>Object.freeze({
    onboarding:canAccessModule(access,'onboarding'),
    billing:canAccessModule(access,'billing')
  });
  const isFullLegacyAdmin=access=>access?.role==='admin'
    &&Object.keys(access.modulePerms).length===1
    &&access.modulePerms['*']==='rw';
  function visibleRoutes(access) {
    return routes.filter(route=>route.key==='access'
      ?access?.role==='super_admin'
      :canAccessModule(access,route.key));
  }
  function roleLabel(role) {
    return role==='super_admin'?'Super admin':role==='sales_staff'?'Sales staff':'Admin';
  }
  function scopeLabel(scope) {
    return scope==='own_created_or_assigned'
      ?'Only firms you created or are assigned to'
      :'All platform records';
  }
  function asArray(payload, keys = []) {
    if (Array.isArray(payload)) return payload;
    for (const key of keys) if (Array.isArray(payload?.[key])) return payload[key];
    return [];
  }
  function missingRpc(error) {
    return error?.code === 'PGRST202' || error?.code === '42883'
      || /function .* does not exist|could not find the function|schema cache|PGRST202/i
      .test(String(error?.message || error || ''));
  }
  async function rpc(sb,name,args = {}) {
    const result = await sb.rpc(name,args);
    if (result?.error) {
      const error = result.error;
      error.platformUpdateRequired = missingRpc(error);
      throw error;
    }
    return result?.data;
  }
  function dateTime(value) {
    if (!value) return '—';
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? String(value) : date.toLocaleString('en-SG',{
      dateStyle:'medium',timeStyle:'short',timeZone:'Asia/Singapore'
    });
  }
  function plainLabel(value) {
    return String(value || '—').replace(/_/g,' ').replace(/\b\w/g,letter=>letter.toUpperCase());
  }
  function moduleLabel(value) {
    const key=String(value||'');
    return sectorModuleByKey.get(key)?.label||plainLabel(key);
  }
  function operationalLaneFor(item) {
    if(item&&typeof item==='object'){
      const explicit=operationalLanes.find(lane=>lane.key===item.lane_key);
      if(explicit)return explicit.key;
    }
    const stage=typeof item==='string'?item:(item?.source_stage_key||item?.lane_key||prospectStage(item));
    return operationalLanes.find(lane=>lane.stages.includes(stage))?.key||'inbox';
  }
  function normalizePlatformPhone(value) {
    let source=String(value||'').trim();
    if(!source)return null;
    const international=source.startsWith('+')||source.startsWith('00');
    let digits=source.replace(/\D/g,'');
    if(source.startsWith('00'))digits=digits.slice(2);
    if(!international&&digits.length===8)digits=`65${digits}`;
    if(digits.length<10||digits.length>15)return null;
    return Object.freeze({tel:`+${digits}`,wa:digits,display:`+${digits}`});
  }
  function platformContactActions(value,CUI,{compact=false}={}) {
    const phone=normalizePlatformPhone(value);
    if(!phone)return'';
    const label=compact?'':'<span>Call</span>';
    const whatsappLabel=compact?'':'<span>WhatsApp</span>';
    return `<div class="platform-contact-actions" data-card-actions>
      <a class="btn ghost sm" href="tel:${escapeHtml(phone.tel)}" title="Call" aria-label="Call ${escapeHtml(phone.display)}">${CUI.icon('till',{size:16})}${label}</a>
      <a class="btn ghost sm" href="https://wa.me/${escapeHtml(phone.wa)}" target="_blank" rel="noopener" title="WhatsApp" aria-label="Open WhatsApp chat with ${escapeHtml(phone.display)}">${CUI.icon('customers',{size:16})}${whatsappLabel}</a>
    </div>`;
  }
  function firmOwnerPhone(firm) {
    return firm.boss_phone||firm.owner_phone||firm.primary_owner_phone
      ||firm.primary_contact_phone||firm.primary_contact?.phone||'';
  }
  function systemUpdateRequired(CUI,title='This platform area') {
    return unavailable(CUI,{
      title,subtitle:'This console is ready, but its platform data contract is not available in this environment.',
      iconName:'info',heading:'System update required',
      body:'No data was changed. Apply the corresponding reviewed platform backend phase, then retry.'
    });
  }
  function showError(host,error,CUI,title) {
    host.innerHTML = error?.platformUpdateRequired
      ? systemUpdateRequired(CUI,title)
      : CUI.errorState({title:`${title} unavailable`,message:error?.message||'Please try again.'});
    CUI.focusRoute(host);
  }
  function closeOverlay(overlay,deactivate) {
    if (deactivate) deactivate();
    else overlay.remove();
  }
  function modal({title,body,submitLabel='Continue',onSubmit,CUI}) {
    const overlay=document.createElement('div');
    overlay.className='platform-modal';overlay.tabIndex=-1;
    overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');
    overlay.setAttribute('aria-labelledby','platformModalTitle');
    overlay.innerHTML=`<div class="platform-modal-panel"><div class="platform-drawer-head">
      <div><h1 id="platformModalTitle" style="font-size:1.35rem">${escapeHtml(title)}</h1></div>
      <button type="button" class="btn ghost sm platform-drawer-close" data-close aria-label="Close dialog">${CUI.icon('close',{size:18})}</button>
    </div><form data-form>${body}<div data-error role="alert"></div><div class="platform-form-actions">
      <button type="button" class="btn ghost" data-close>Cancel</button>
      <button type="submit" class="btn" data-submit>${escapeHtml(submitLabel)}</button>
    </div></form></div>`;
    document.body.appendChild(overlay);
    let deactivate;
    const close=()=>closeOverlay(overlay,deactivate);
    overlay.querySelectorAll('[data-close]').forEach(button=>button.onclick=close);
    overlay.querySelector('[data-form]').onsubmit=async event=>{
      event.preventDefault();
      const submit=overlay.querySelector('[data-submit]'),errorHost=overlay.querySelector('[data-error]');
      submit.disabled=true;errorHost.innerHTML='';
      try{await onSubmit(new FormData(event.currentTarget),{overlay,close,errorHost,submit})}
      catch(error){errorHost.innerHTML=`<div class="err">${escapeHtml(error?.message||'That action could not be completed.')}</div>`;submit.disabled=false}
    };
    deactivate=CUI.activateDialog(overlay,{onClose:close});
    return overlay;
  }
  function previewThenConfirm({title,preview,CUI,onConfirm}) {
    modal({
      title,submitLabel:'Confirm change',CUI,
      body:`<div class="platform-preview"><b>Preview</b><pre>${escapeHtml(JSON.stringify(preview,null,2))}</pre></div>
        <label class="row" style="align-items:flex-start;margin-top:14px;color:var(--ink)"><input name="confirmed" type="checkbox" value="yes" required style="width:20px;min-width:20px;min-height:20px"><span>I reviewed this preview and want to apply it.</span></label>`,
      onSubmit:async(form,controls)=>{
        if(form.get('confirmed')!=='yes')throw new Error('Review and confirm the preview first.');
        await onConfirm(controls);
      }
    });
  }

  function isRoute(hash) {
    return /^#\/platform(?:\/(?:onboarding|firms|reports|billing|commissions|sectors|automation|access))?\/?$/.test(String(hash || '').split('?')[0]);
  }

  function routeKey(hash) {
    const path = String(hash || '').split('?')[0].replace(/\/+$/,'');
    if (path === '#/platform' || path === '#') return 'overview';
    const requested = path.slice('#/platform/'.length);
    return routes.some(route => route.key === requested) ? requested : 'overview';
  }

  function navigationHtml(CUI, activeKey, allowedRoutes, mobile = false) {
    const className = mobile ? 'platform-mobile-nav' : 'platform-nav';
    const label = mobile ? 'Platform sections' : 'Platform navigation';
    if(mobile){
      const primary=allowedRoutes.filter(route=>['overview','onboarding','firms','reports'].includes(route.key)).slice(0,4);
      const secondary=allowedRoutes.filter(route=>!primary.includes(route));
      const moreActive=secondary.some(route=>route.key===activeKey);
      return `<nav class="${className}" aria-label="${label}" style="--platform-mobile-count:${Math.min(primary.length+(secondary.length?1:0),5)}">
        ${primary.map(route=>{
          const active=route.key===activeKey;
          return `<a href="${route.hash}"${active?' aria-current="page"':''}>${CUI.icon(route.icon,{size:19})}<span>${escapeHtml(route.shortLabel)}</span></a>`;
        }).join('')}
        ${secondary.length?`<details class="platform-mobile-more"${moreActive?' data-active="true"':''}>
          <summary${moreActive?' aria-current="page"':''}>${CUI.icon('setup',{size:19})}<span>More</span></summary>
          <div class="platform-mobile-more-menu" role="list">${secondary.map(route=>{
            const active=route.key===activeKey;
            return `<a role="listitem" href="${route.hash}"${active?' aria-current="page"':''}>${CUI.icon(route.icon,{size:18})}<span>${escapeHtml(route.label)}</span></a>`;
          }).join('')}</div>
        </details>`:''}
      </nav>`;
    }
    return `<nav class="${className}" aria-label="${label}">${allowedRoutes.map(route => {
      const active = route.key === activeKey;
      return `<a href="${route.hash}"${active?' aria-current="page"':''}>${CUI.icon(route.icon,{size:19})}<span>${escapeHtml(mobile?route.shortLabel:route.label)}</span></a>`;
    }).join('')}</nav>`;
  }

  function wordmarkHtml(brand) {
    const wordmark = String(brand.wordmark || 'nestly.');
    const dot = wordmark.endsWith('.') ? '<span>.</span>' : '';
    return `${escapeHtml(dot ? wordmark.slice(0,-1) : wordmark)}${dot}`;
  }

  function shellHtml({CUI,brand,activeKey,workspaceHash,access,allowedRoutes}) {
    const route = routes.find(item => item.key === activeKey) || routes[0];
    return `<div class="platform-console">
      <a class="skip-link" href="#platformMain">Skip to platform content</a>
      <aside class="platform-rail" aria-label="Platform console">
        <div class="platform-brand"><a href="#/platform" class="logo" aria-label="${escapeHtml(brand.productName)} platform home">${wordmarkHtml(brand)}</a><span class="platform-tag">Platform</span></div>
        <div class="platform-access-summary" aria-label="Current platform access">
          <b>${escapeHtml(roleLabel(access.role))}</b>
          <span>${escapeHtml(scopeLabel(access.scope))} · ${activeKey==='access'||modulePermission(access,activeKey)==='rw'?'Read and write':'Read only'}</span>
        </div>
        ${navigationHtml(CUI,activeKey,allowedRoutes)}
        <div class="platform-rail-foot"><a class="platform-back" href="${escapeHtml(workspaceHash)}">${CUI.icon('back',{size:17})}<span>Back to workspace</span></a></div>
      </aside>
      <div class="platform-column">
        <header class="platform-topbar">
          <div class="platform-topbar-title">${escapeHtml(route.label)}</div>
          <div class="platform-topbar-actions">
            <a class="btn ghost sm" href="${escapeHtml(workspaceHash)}" aria-label="Back to workspace">${CUI.icon('back',{size:17})}<span>Workspace</span></a>
            <button class="btn ghost sm" type="button" id="platformSignOut">${CUI.icon('close',{size:17})}<span>Sign out</span></button>
          </div>
        </header>
        <main class="platform-main" id="platformMain" tabindex="-1"></main>
      </div>
      ${navigationHtml(CUI,activeKey,allowedRoutes,true)}
    </div>`;
  }

  function platformAccessDeniedHtml({CUI,brand,workspaceHash,onSignOut}) {
    return `<main class="platform-denied" id="platformMain" tabindex="-1">
      <div class="platform-denied-brand logo">${wordmarkHtml(brand||{})}</div>
      ${CUI.errorState({
        title:'Platform access unavailable',
        message:'This account has no active Nestly platform role. Ask a super admin to grant or reactivate access.'
      })}
      <div class="platform-actions">
        <a class="btn ghost" href="${escapeHtml(workspaceHash)}">Back to workspace</a>
        <button type="button" class="btn ghost" id="platformDeniedSignOut">Sign out</button>
      </div>
    </main>`;
  }

  function currency(cents, currencyCode = 'SGD') {
    const safe = Number.isFinite(Number(cents)) ? Number(cents) : 0;
    return `${currencyCode} ${(safe / 100).toFixed(2)}`;
  }
  function formatFileSize(bytes) {
    const value=Number(bytes);
    if(!Number.isFinite(value)||value<1)return'—';
    if(value<1024)return`${value} B`;
    if(value<1048576)return`${(value/1024).toFixed(value<10240?1:0)} KB`;
    return`${(value/1048576).toFixed(value<10485760?1:0)} MB`;
  }

  function statusTone(status) {
    return status === 'active' ? 'ok' : status === 'trialing' ? 'new' : status === 'past_due' ? 'no' : 'off';
  }

  function firmRows(rows, CUI) {
    return rows.map(row => [
      `<b>${escapeHtml(row.name || 'Unnamed firm')}</b>`,
      escapeHtml(row.industry || '—'),
      String(row.branch_count ?? 0),
      String(row.staff_count ?? 0),
      String(row.client_count ?? 0),
      String(row.billable_seats ?? 0),
      CUI.status(row.subscription_status || 'none',statusTone(row.subscription_status)),
      `<span style="font-variant-numeric:tabular-nums">${currency(row.est_monthly_cents)}</span>`
    ]);
  }

  function loading(CUI, title, subtitle, iconName) {
    return CUI.loadingState({title,body:subtitle,iconName});
  }

  function unavailable(CUI, {title,subtitle,iconName,heading,body}) {
    return `${CUI.pageHeader({title,subtitle,iconName})}${CUI.card({
      className:'platform-state-card',
      body:CUI.emptyState({iconName,title:heading,body})
    })}`;
  }

  function overviewHtml(rows, CUI) {
    const totals = rows.reduce((summary,row) => ({
      firms:summary.firms + 1,
      seats:summary.seats + Number(row.billable_seats || 0),
      monthly:summary.monthly + Number(row.est_monthly_cents || 0),
      trials:summary.trials + (row.subscription_status === 'trialing' ? 1 : 0)
    }),{firms:0,seats:0,monthly:0,trials:0});
    const list = rows.slice(0,8);
    return `${CUI.pageHeader({
      title:'Platform overview',
      subtitle:'A current read-only view of firms and subscription projections already available to the platform.',
      iconName:'platform'
    })}
      <section class="platform-kpis" aria-label="Platform summary">
        ${[
          ['Firms',totals.firms,'branch'],
          ['Billable seats',totals.seats,'staff'],
          ['Projected monthly',currency(totals.monthly),'reports'],
          ['Trials',totals.trials,'retention']
        ].map(([label,value,icon])=>`<article class="card platform-kpi"><div class="platform-kpi-label">${CUI.icon(icon,{size:17})}<span>${escapeHtml(label)}</span></div><div class="platform-kpi-value">${escapeHtml(value)}</div></article>`).join('')}
      </section>
      <div class="platform-section-grid">
        ${CUI.card({
          title:'Firm snapshot',
          description:list.length?'The current roster, ordered by the platform data source.':'No firms are available from the current platform data source.',
          body:list.length?CUI.table({
            caption:'Platform firm snapshot',
            headers:['Firm','Sector','Branches','Staff','Customers','Seats','Subscription','Projected monthly'],
            rows:firmRows(list,CUI),
            className:'platform-firms-table'
          }):CUI.emptyState({iconName:'branch',title:'No firms yet',body:'The platform roster returned no firms.'})
        })}
        ${CUI.card({
          title:'What this view means',
          body:`<dl class="platform-context-list">
            <div><dt>Revenue</dt><dd>Projection only</dd></div>
            <div><dt>Payments collected</dt><dd>Not available</dd></div>
            <div><dt>Onboarding lifecycle</dt><dd>Evidence controlled</dd></div>
            <div><dt>Automation runs</dt><dd>Not connected</dd></div>
          </dl>`
        })}
      </div>`;
  }

  function firmsHtml(rows, CUI) {
    return `${CUI.pageHeader({
      title:'Firms',
      subtitle:'Every firm returned by the existing super-admin roster. No firm data is inferred.',
      iconName:'branch'
    })}${CUI.card({
      title:'Firm directory',
      description:rows.length?`${rows.length} firm${rows.length===1?'':'s'} available.`:'The platform roster is empty.',
      body:rows.length?CUI.table({
        caption:'Platform firm directory',
        headers:['Firm','Sector','Branches','Staff','Customers','Seats','Subscription','Projected monthly'],
        rows:firmRows(rows,CUI),
        className:'platform-firms-table'
      }):CUI.emptyState({iconName:'branch',title:'No firms yet',body:'The existing super-admin roster returned no records.'})
    })}`;
  }

  const enterpriseSectors = Object.freeze([
    ['','All sectors'],['fnb','F&B / Café'],['salon','Hair Salon'],
    ['facial','Facial / Spa'],['massage','Massage'],['fitness','Fitness'],
    ['retail','Retail'],['other','Other']
  ]);
  function singaporeIsoDate(date = new Date()) {
    const parts=Object.fromEntries(new Intl.DateTimeFormat('en-CA',{
      timeZone:'Asia/Singapore',year:'numeric',month:'2-digit',day:'2-digit'
    }).formatToParts(date).filter(part=>part.type!=='literal').map(part=>[part.type,part.value]));
    return `${parts.year}-${parts.month}-${parts.day}`;
  }
  function enterpriseDefaults() {
    const to=singaporeIsoDate(),fromDate=new Date(`${to}T00:00:00+08:00`);
    fromDate.setUTCFullYear(fromDate.getUTCFullYear()-1);
    return {sector:'',businesses:[],branch:'',search:'',from:singaporeIsoDate(fromDate),to};
  }
  function selectedOptions(select) {
    return Array.from(select?.selectedOptions||[],option=>option.value).filter(Boolean);
  }
  function csvCell(value) {
    const text=String(value??'');
    return /[",\r\n]/.test(text)?`"${text.replace(/"/g,'""')}"`:text;
  }
  function downloadCsv(filename,rows) {
    const blob=new Blob([rows.map(row=>row.map(csvCell).join(',')).join('\r\n')+'\r\n'],{
      type:'text/csv;charset=utf-8'
    });
    const url=globalObject.URL.createObjectURL(blob),link=document.createElement('a');
    link.href=url;link.download=filename;link.click();
    globalObject.URL.revokeObjectURL(url);
  }
  function enterpriseArgs(filters) {
    return {
      p_sector:filters.sector||null,
      p_businesses:filters.businesses?.length?filters.businesses:null,
      p_branch:filters.branch||null,
      p_from:filters.from,
      p_to:filters.to,
      p_search:filters.search||null
    };
  }
  async function fetchEnterpriseFirmPages(sb,filters) {
    let snapshot=null,cursor=null,first=null;
    const firms=[],seen=new Set();
    do{
      const payload=asObject(await rpc(sb,'platform_get_enterprise_hierarchy_v82',{
        ...enterpriseArgs(filters),p_limit:500,p_snapshot_at:snapshot,
        p_after_created_at:cursor?.created_at||null,
        p_after_business:cursor?.business_id||null
      }));
      if(!first)first=payload;
      snapshot=snapshot||payload.snapshot_at;
      asArray(payload,['firms']).forEach(firm=>{
        const id=firmId(firm);
        if(id&&!seen.has(id)){seen.add(id);firms.push(firm)}
      });
      const page=asObject(payload.pagination),next=asObject(page.next_cursor);
      cursor=page.has_more&&next.created_at&&next.business_id?next:null;
      if(cursor){
        const token=`${cursor.created_at}:${cursor.business_id}`;
        if(seen.has(`cursor:${token}`))throw new Error('Firm paging did not advance.');
        seen.add(`cursor:${token}`);
      }
    }while(cursor);
    const payload=first||{};
    return {...payload,snapshot_at:snapshot,firms,pagination:{
      ...asObject(payload.pagination),returned_firms:firms.length,has_more:false,next_cursor:null
    }};
  }
  async function fetchFirmDirectoryV88(sb,filters,{required=false}={}) {
    const items=[],seen=new Set(),seenCursors=new Set();
    let snapshot=null,cursor=null,totalCount=0,attentionSummary={};
    try{
      do{
        const payload=asObject(await rpc(sb,'platform_list_firm_onboarding_v88',{
          p_filters:{
            search:filters.search||null,
            sector:filters.sector||null,
            lane:filters.lane||null
          },
          p_snapshot_at:snapshot,
          p_limit:100,
          p_after_updated_at:cursor?.updated_at||null,
          p_after_id:cursor?.id||null
        }));
        snapshot=snapshot||payload.snapshot_at;
        totalCount=Number(payload.total_count||0);
        if(!Object.keys(attentionSummary).length)attentionSummary=asObject(payload.attention_summary);
        asArray(payload,['items']).forEach(item=>{
          const id=firmId(item);
          if(id&&!seen.has(id)){seen.add(id);items.push(item)}
        });
        const next=asObject(payload.next_cursor);
        if(next.id){
          const token=`${next.updated_at||''}:${next.id}`;
          if(seenCursors.has(token))throw new Error('Firm directory paging did not advance.');
          seenCursors.add(token);cursor=next;
        }else cursor=null;
      }while(cursor);
      return{items,total_count:totalCount,snapshot_at:snapshot,attention_summary:attentionSummary};
    }catch(error){
      if(missingRpc(error)&&!required)return null;
      throw error;
    }
  }
  function mergeFirmDirectoryData(firms,directoryItems) {
    const directoryByBusiness=new Map(asArray(directoryItems)
      .filter(item=>item.business_id)
      .map(item=>[String(item.business_id),item]));
    return firms.map(firm=>({...firm,...asObject(directoryByBusiness.get(firmId(firm))),
      summary:firm.summary,branches:firm.branches,currency:firm.currency
    }));
  }
  async function fetchEnterpriseCustomerPage(sb,filters,snapshot,cursor=null) {
    return asObject(await rpc(sb,'platform_list_enterprise_customers_v82',{
      ...enterpriseArgs(filters),p_limit:500,p_snapshot_at:snapshot||null,
      p_after_created_at:cursor?.created_at||null,
      p_after_client:cursor?.client_id||null
    }));
  }
  async function fetchAllEnterpriseCustomers(sb,filters,snapshot) {
    const customers=[],seenCustomers=new Set(),seenCursors=new Set();
    let cursor=null;
    do{
      const payload=await fetchEnterpriseCustomerPage(sb,filters,snapshot,cursor);
      asArray(payload,['customers']).forEach(customer=>{
        const id=String(customer.client_id||'');
        if(id&&!seenCustomers.has(id)){seenCustomers.add(id);customers.push(customer)}
      });
      const page=asObject(payload.pagination),next=asObject(page.next_cursor);
      cursor=page.has_more&&next.created_at&&next.client_id?next:null;
      if(cursor){
        const token=`${cursor.created_at}:${cursor.client_id}`;
        if(seenCursors.has(token))throw new Error('Customer paging did not advance.');
        seenCursors.add(token);
      }
    }while(cursor);
    return customers;
  }
  function firmId(firm) {
    return String(firm.business_id||firm.id||firm.row_id||firm.prospect_id||'');
  }
  function resolveEnterpriseSearchBusinessIds(directoryItems,hierarchyFirms,selectedBusinesses=[]) {
    const selected=new Set(asArray(selectedBusinesses).map(String));
    const resolved=new Set([
      ...asArray(directoryItems).filter(item=>item.business_id).map(item=>String(item.business_id)),
      ...asArray(hierarchyFirms).map(firmId).filter(Boolean)
    ]);
    return [...resolved].filter(id=>!selected.size||selected.has(id));
  }
  function firmRegistrationNumber(firm) {
    return firm.registration_number||firm.uen||firm.company_registration_number||'';
  }
  function firmOwnerName(firm) {
    return firm.boss_name||firm.owner_name||firm.primary_owner_name||firm.primary_contact_name||'';
  }
  function firmOwnerEmail(firm) {
    return firm.boss_email||firm.owner_email||firm.primary_owner_email||firm.primary_contact_email||'';
  }
  function enterpriseFirmRows(firms,CUI) {
    return firms.map(firm=>[
      `<button type="button" class="platform-link-button" data-enterprise-firm="${escapeHtml(firmId(firm))}"><b>${escapeHtml(firm.name||firm.legal_name||'Unnamed firm')}</b></button>
        ${firmRegistrationNumber(firm)?`<span class="muted small platform-firm-secondary">${escapeHtml(firmRegistrationNumber(firm))}</span>`:''}`,
      escapeHtml(plainLabel(firm.sector_key||firm.industry)),
      `<span>${escapeHtml(firmOwnerName(firm)||'—')}</span>${firmOwnerEmail(firm)?`<span class="muted small platform-firm-secondary">${escapeHtml(firmOwnerEmail(firm))}</span>`:''}`,
      platformContactActions(firmOwnerPhone(firm),CUI,{compact:true})||'<span class="muted small">No phone</span>',
      String(firm.branch_count??asArray(firm.branches).length),
      String(firm.customer_count??asArray(firm.customers).length),
      currency(firm.summary?.net_revenue_cents,firm.currency||'SGD'),
      String(firm.summary?.returning_customers??0),
      String(firm.summary?.completed_transactions??0),
      `<button type="button" class="btn ghost sm" data-enterprise-firm="${escapeHtml(firmId(firm))}">${CUI.icon('forward',{size:16})}<span>Open</span></button>`
    ]);
  }
  function enterpriseBranchOptions(filters,catalog) {
    const selected=filters.businesses||[];
    if(selected.length!==1)return [];
    const firm=catalog.find(row=>firmId(row)===selected[0]);
    return asArray(firm?.branches);
  }
  function enterpriseHtml(payload,CUI,filters,catalog,canGenerateReport=false) {
    const firms=asArray(payload,['firms']),pagination=asObject(payload.pagination);
    const branches=enterpriseBranchOptions(filters,catalog);
    return `${CUI.pageHeader({
      title:'Enterprise data',
      subtitle:'Inspect every firm from company level down to branches and customer records, using one explicit reporting scope.',
      iconName:'branch'
    })}
      <form class="card platform-enterprise-filters" id="enterpriseFilters">
        <div class="platform-enterprise-filter-grid">
          <div class="platform-enterprise-search">${CUI.field({id:'enterpriseSearch',label:'Find a firm or customer',type:'search',value:filters.search,placeholder:'Name, sector, UEN, owner phone or email'})}
            <p class="muted small">Search is applied on the server across the complete directory, so it remains usable as the platform grows.</p>
          </div>
          ${CUI.field({id:'enterpriseSector',label:'Sector',control:'select',options:enterpriseSectors.map(([value,label])=>({value,label,selected:value===filters.sector}))})}
          <div class="cui-field platform-enterprise-firms"><label for="enterpriseBusinesses">Firm scope <span class="muted small">(select one or more)</span></label>
            <select id="enterpriseBusinesses" multiple size="5">${catalog.map(firm=>`<option value="${escapeHtml(firmId(firm))}"${filters.businesses.includes(firmId(firm))?' selected':''}>${escapeHtml(firm.name)} · ${escapeHtml(plainLabel(firm.industry))}</option>`).join('')}</select>
            <p class="muted small">No selection means every firm in the sector.</p>
          </div>
          <div class="cui-field"><label for="enterpriseBranch">Branch</label><select id="enterpriseBranch"${filters.businesses.length===1?'':' disabled'}>
            <option value="">Whole firm</option>${branches.map(branch=>`<option value="${escapeHtml(branch.branch_id)}"${branch.branch_id===filters.branch?' selected':''}>${escapeHtml(branch.name)}</option>`).join('')}
          </select><p class="muted small">${filters.businesses.length===1?'Choose one branch or keep the whole firm.':'Select exactly one firm to filter by branch.'}</p></div>
          ${CUI.field({id:'enterpriseFrom',label:'From',type:'date',value:filters.from})}
          ${CUI.field({id:'enterpriseTo',label:'To',type:'date',value:filters.to})}
        </div>
        <div class="platform-actions">
          <button class="btn" type="submit">${CUI.icon('search',{size:17})}<span>Apply scope</span></button>
          <button class="btn ghost" type="button" id="enterpriseClear">Clear</button>
          ${canGenerateReport?`<button class="btn ghost" type="button" id="enterpriseGenerateReport"${firms.length?'':' disabled title="No matching firms are available to report."'}>${CUI.icon('reports',{size:17})}<span>Generate detailed report</span></button>`:''}
        </div>
      </form>
      <div class="platform-route-note platform-status-note">${CUI.icon('info',{size:19})}<div><b>Complete snapshot</b><p class="small">${escapeHtml(pagination.total_firms??firms.length)} matching firm${Number(pagination.total_firms??firms.length)===1?'':'s'} as at ${escapeHtml(dateTime(payload.snapshot_at))}. Search applies consistently to the directory and report.</p></div></div>
      ${CUI.card({
        title:'Firm, branch and customer directory',
        description:firms.length?`${firms.length} firm${firms.length===1?'':'s'} in this scope. Open a firm for branch and customer detail.`:'No firms match this scope.',
        body:firms.length?CUI.table({
          caption:'Enterprise firm directory',
          headers:['Firm / UEN','Sector','Owner','Contact','Branches','Customers','Net revenue','Returning','Transactions',''],
          rows:enterpriseFirmRows(firms,CUI),
          className:'platform-firms-table platform-enterprise-table'
        }):CUI.emptyState({iconName:'branch',title:'No matching firms',body:'Change the sector, firm, branch, date or search scope.'})
      })}
      <section id="enterpriseReportHost" class="platform-report-host" aria-live="polite"></section>`;
  }
  function enterpriseDetailTable(firm,CUI,customers=[],pagination={}) {
    const branches=asArray(firm.branches);
    const ownerPhone=firmOwnerPhone(firm);
    return `<div class="platform-detail-grid">
      ${CUI.card({title:'Scope summary',body:`<dl class="platform-context-list">
        <div><dt>Net revenue</dt><dd>${escapeHtml(currency(firm.summary?.net_revenue_cents,firm.currency||'SGD'))}</dd></div>
        <div><dt>Cash collected</dt><dd>${escapeHtml(currency(firm.summary?.cash_collected_cents,firm.currency||'SGD'))}</dd></div>
        <div><dt>Completed transactions</dt><dd>${escapeHtml(firm.summary?.completed_transactions??0)}</dd></div>
        <div><dt>Returning customers</dt><dd>${escapeHtml(firm.summary?.returning_customers??0)}</dd></div>
      </dl>`})}
      ${CUI.card({title:'Firm record',body:`<dl class="platform-context-list">
        <div><dt>Legal name</dt><dd>${escapeHtml(firm.legal_name||firm.name||'—')}</dd></div>
        <div><dt>UEN</dt><dd>${escapeHtml(firmRegistrationNumber(firm)||'—')}</dd></div>
        <div><dt>Sector</dt><dd>${escapeHtml(plainLabel(firm.sector_key||firm.industry))}</dd></div>
        <div><dt>Owner / boss</dt><dd>${escapeHtml(firmOwnerName(firm)||'—')}</dd></div>
        <div><dt>Owner email</dt><dd>${firmOwnerEmail(firm)?`<a href="mailto:${escapeHtml(firmOwnerEmail(firm))}">${escapeHtml(firmOwnerEmail(firm))}</a>`:'—'}</dd></div>
        <div><dt>Branches</dt><dd>${escapeHtml(firm.branch_count??branches.length)}</dd></div>
        <div><dt>Staff</dt><dd>${escapeHtml(firm.staff_count??0)}</dd></div>
        <div><dt>Customers</dt><dd>${escapeHtml(firm.customer_count??pagination.total_customers??customers.length)}</dd></div>
      </dl>${platformContactActions(ownerPhone,CUI)}`})}
    </div>
    <section class="platform-detail-section"><h2>Branches</h2>${branches.length?CUI.table({
      caption:`${firm.name} branches`,
      headers:['Branch','Status','Customers','Staff','Net revenue','Transactions',''],
      rows:branches.map(branch=>[
        `<b>${escapeHtml(branch.name)}</b>${branch.is_default?' <span class="pill">Default</span>':''}`,
        CUI.status(branch.active?'Active':'Inactive',branch.active?'ok':'off'),
        String(branch.customer_count??0),String(branch.staff_count??0),
        currency(branch.net_revenue_cents,firm.currency||'SGD'),
        String(branch.completed_transactions??0),
        `<button type="button" class="btn ghost sm" data-enterprise-branch="${escapeHtml(branch.branch_id)}">View customers</button>`
      ])
    }):CUI.emptyState({iconName:'branch',title:'No branches',body:'No branch records were returned.'})}</section>
    <section class="platform-detail-section"><div class="platform-list-row"><h2>Customers</h2><span class="muted small">${escapeHtml(pagination.total_customers??customers.length)} total in scope</span></div>${customers.length?CUI.table({
      caption:`${firm.name} customers`,
      headers:['Customer','Contact','Net revenue','Transactions','Visits','First purchase','Last purchase'],
      rows:customers.map(customer=>[
        `<b>${escapeHtml(customer.full_name)}</b>`,
        `<span>${escapeHtml(customer.phone||'—')}</span><br><span class="muted small">${escapeHtml(customer.email||'—')}</span>`,
        currency(customer.net_revenue_cents,firm.currency||'SGD'),
        String(customer.completed_transactions??0),String(customer.visit_count??0),
        escapeHtml(dateTime(customer.first_purchase_at)),escapeHtml(dateTime(customer.last_purchase_at))
      ])
    }):CUI.emptyState({iconName:'customers',title:'No customers in this scope',body:'Choose the whole firm or another branch/date range.'})}
    ${pagination.has_more?'<div class="platform-actions"><button type="button" class="btn ghost sm" id="enterpriseCustomersMore">Load more customers</button></div>':''}</section>`;
  }
  function workspaceControlTone(value) {
    return value==='approved'||value==='active'||value==='open'?'ok'
      :value==='pending'||value==='grace'?'new':'no';
  }
  function moduleControlRows(effective,CUI,{branchId=null,canWrite=false}={}) {
    const modules=asArray(effective?.modules)
      .filter(module=>!['inventory','customerintel'].includes(module.module_key));
    if(!modules.length)return'<p class="muted small">No business modules are enabled in this scope.</p>';
    return CUI.table({
      caption:branchId?'Branch effective modules':'Firm effective modules',
      headers:['Module','Access','Source',...(canWrite?['']:[])],
      rows:modules.map(module=>[
        `<b>${escapeHtml(moduleLabel(module.module_key))}</b>`,
        CUI.status(module.mode==='rw'?'Read & write':module.mode==='r'?'Read only':'Off',module.mode==='rw'?'ok':module.mode==='r'?'new':'off'),
        escapeHtml(plainLabel(module.source||'inherited')),
        ...(canWrite?[`<button type="button" class="btn ghost sm" data-module-control="${escapeHtml(module.module_key)}" data-branch-id="${escapeHtml(branchId||'')}" data-module-version="${escapeHtml(module.version??'')}">Edit</button>`]:[])
      ])
    });
  }
  function firmGovernanceHtml(firm,CUI,control,effective,context) {
    const approval=asObject(control.approval),subscription=asObject(control.subscription);
    const representative=asObject(control.representative),catalogue=asObject(control.catalogue_intelligence);
    const canWrite=context.access?.role==='super_admin';
    const approvalStatus=approval.status||'pending';
    const subscriptionState=subscription.state||'unknown';
    const contact=normalizePlatformPhone(representative.hotline_phone);
    return `<section class="card platform-detail-section platform-governance" aria-labelledby="firmGovernanceTitle">
      <div class="platform-list-row"><div><h2 id="firmGovernanceTitle">Workspace control</h2><p class="muted small">Approval, payment access and module policy are enforced by the server as well as this console.</p></div>${CUI.status(control.workspace_access?'Workspace open':'Workspace blocked',control.workspace_access?'ok':'no')}</div>
      <div class="platform-detail-grid">
        ${CUI.card({title:'Firm approval',body:`<div class="platform-control-status">${CUI.status(plainLabel(approvalStatus),workspaceControlTone(approvalStatus))}<span class="muted small">Version ${escapeHtml(approval.version??0)}</span></div>
          <p class="muted small">${approvalStatus==='approved'?'Approved firms may enter the workspace when billing is also clear.':approvalStatus==='rejected'?'This application was rejected. The firm cannot enter the workspace.':'Awaiting a super-admin decision. No business data is exposed in the workspace.'}</p>
          ${canWrite&&approvalStatus!=='approved'?`<div class="platform-actions"><button type="button" class="btn sm" data-business-approval="approved">Approve firm</button><button type="button" class="btn danger sm" data-business-approval="rejected">Reject</button></div>`:''}`})}
        ${CUI.card({title:'Subscription access',body:`<div class="platform-control-status">${CUI.status(plainLabel(subscriptionState),workspaceControlTone(subscriptionState))}<span class="muted small">${subscription.overdue_day===null||subscription.overdue_day===undefined?'No overdue day':`Day ${escapeHtml(subscription.overdue_day)} overdue`}</span></div>
          <dl class="platform-context-list"><div><dt>Due date</dt><dd>${escapeHtml(subscription.due_date||'—')}</dd></div><div><dt>Workspace paused</dt><dd>${subscription.workspace_paused?'Yes':'No'}</dd></div></dl>
          ${subscription.workspace_paused?`<p class="small">Owner access resumes only after provider payment truth is reconciled.</p>${contact?`<a class="btn ghost sm" href="tel:${escapeHtml(contact.tel)}">Contact ${escapeHtml(representative.display_name||'assigned representative')}</a>`:''}`:'<p class="muted small">Daily reminders run from the due date. Owner access pauses on day 14 if the invoice remains unpaid.</p>'}`})}
      </div>
      <div class="platform-list-row platform-control-heading"><div><h3>Firm module policy</h3><p class="muted small">Branch overrides take priority over firm and sector settings. Inventory is globally unavailable to firms.</p></div>
        ${canWrite?`<button type="button" class="btn ghost sm" data-module-control="" data-branch-id="">Edit firm modules</button>`:''}
      </div>
      ${moduleControlRows(effective,CUI,{canWrite})}
      ${asArray(firm.branches).length?`<div class="platform-branch-control-list" aria-label="Branch module controls">${asArray(firm.branches).map(branch=>`
        <div class="platform-action-item"><div><b>${escapeHtml(branch.name)}</b><p class="muted small">Branch-specific settings override firm policy.</p></div>
          ${canWrite?`<button type="button" class="btn ghost sm" data-manage-branch="${escapeHtml(branch.branch_id)}">Manage branch</button>`:''}
        </div>`).join('')}</div>`:''}
      <div class="platform-list-row platform-control-heading"><div><h3>Item-level intelligence</h3><p class="muted small">When enabled, Quick Earn uses the firm catalogue and platform reports can analyse product and service patterns.</p></div>
        ${canWrite?`<button type="button" class="btn ghost sm" data-catalogue-intelligence="${catalogue.enabled?'disable':'enable'}">${catalogue.enabled?'Disable':'Enable'}</button>`:''}
      </div>
      <p>${catalogue.enabled?'Enabled for catalogue-first sales and item-level intelligence.':'Disabled. Quick Earn can fall back to authorised custom-amount sales; no item affinity claims are generated.'}</p>
    </section>`;
  }
  function businessApprovalModal(firm,decision,control,context,refresh) {
    const {CUI,sb}=context,approval=asObject(control.approval);
    modal({
      title:`${decision==='approved'?'Approve':'Reject'} ${firm.name}`,
      submitLabel:decision==='approved'?'Confirm approval':'Confirm rejection',
      CUI,
      body:CUI.field({
        id:'businessApprovalReason',label:'Decision note',control:'textarea',required:true,
        hint:'This note is retained in the platform audit trail.',
        attributes:'name="reason" rows="4" minlength="3" maxlength="1000"'
      }),
      onSubmit:async(form,controls)=>{
        await rpc(sb,'platform_decide_business_approval_v94',{
          p_business:firmId(firm),p_decision:decision,p_reason:String(form.get('reason')).trim(),
          p_expected_version:Number(approval.version||0)
        });
        controls.close();await refresh();CUI.announce(`Firm ${decision}.`);
      }
    });
  }
  function moduleControlModal(firm,effective,context,refresh,{branchId=null,moduleKey=''}={}) {
    const {CUI,sb}=context;
    const branches=asArray(firm.branches);
    const selected=asArray(effective?.modules).find(module=>module.module_key===moduleKey);
    const available=sectorModuleCatalog.filter(module=>module.key!=='inventory');
    modal({
      title:branchId?'Edit branch modules':'Edit firm modules',submitLabel:'Apply module policy',CUI,
      body:`<div class="platform-form-grid">
        ${CUI.field({id:'moduleControlBranch',label:'Scope',control:'select',options:branchId
          ?branches.filter(branch=>branch.branch_id===branchId).map(branch=>({value:branch.branch_id,label:`Branch · ${branch.name}`,selected:true}))
          :[{value:'',label:'Whole firm',selected:true}],attributes:'name="branch_id"'})}
        ${CUI.field({id:'moduleControlKey',label:'Module',control:'select',options:available.map(module=>({value:module.key,label:module.label,selected:module.key===moduleKey})),attributes:'name="module_key"'})}
        ${CUI.field({id:'moduleControlMode',label:'Access',control:'select',options:[
          {value:'inherit',label:'Use inherited setting'},
          {value:'disabled',label:'Off'},
          {value:'r',label:'Read only'},
          {value:'rw',label:'Read & write'}
        ].map(option=>({...option,selected:option.value===(selected?.override_mode||'inherit')})),attributes:'name="mode"'})}
        <div class="wide">${CUI.field({id:'moduleControlReason',label:'Reason',control:'textarea',required:true,attributes:'name="reason" rows="4" minlength="3" maxlength="1000"'})}</div>
      </div>
      <div class="platform-route-note"><b>Inventory is not available here</b><p class="small">Nestly keeps inventory off for every firm, independent of sector or branch settings.</p></div>`,
      onSubmit:async(form,controls)=>{
        const module=String(form.get('module_key'));
        const scopeBranch=String(form.get('branch_id')||'')||null;
        const current=asArray(effective?.modules).find(row=>row.module_key===module);
        await rpc(sb,'platform_set_module_override_v94',{
          p_business:firmId(firm),p_branch:scopeBranch,p_module:module,
          p_mode:String(form.get('mode')),p_reason:String(form.get('reason')).trim(),
          p_expected_version:current?.version??null
        });
        controls.close();await refresh();CUI.announce(`${moduleLabel(module)} policy updated.`);
      }
    });
  }
  function openEnterpriseFirm(firm,context,filters) {
    const {CUI,sb}=context,overlay=document.createElement('div');
    overlay.className='platform-drawer';overlay.tabIndex=-1;
    overlay.innerHTML=`<section class="platform-drawer-panel platform-enterprise-drawer" aria-labelledby="enterpriseFirmTitle">
      <div class="platform-drawer-head"><div><h1 id="enterpriseFirmTitle" style="font-size:1.45rem">${escapeHtml(firm.name)}</h1><p class="muted small">${escapeHtml(plainLabel(firm.industry))} · ${escapeHtml(filters.from)} to ${escapeHtml(filters.to)}</p></div><button type="button" class="btn ghost sm platform-drawer-close" aria-label="Close detail">${CUI.icon('close',{size:18})}</button></div>
      <div id="enterpriseFirmBody">${loading(CUI,'Customer records','Loading the first complete-snapshot page…','customers')}</div>
    </section>`;
    document.body.appendChild(overlay);
    let deactivate;
    const close=()=>closeOverlay(overlay,deactivate);
    overlay.querySelector('.platform-drawer-close').onclick=close;
    deactivate=CUI.activateDialog(overlay,{onClose:close,initialFocus:'.platform-drawer-close'});
    const scopedFilters={...filters,businesses:[firmId(firm)]};
    const body=overlay.querySelector('#enterpriseFirmBody');
    let customers=[],page={},snapshot=context.enterpriseSnapshot||null;
    let control={},effective={};
    const renderBody=()=>{
      body.innerHTML=`${firmGovernanceHtml(firm,CUI,control,effective,context)}${enterpriseDetailTable(firm,CUI,customers,page)}`;
      bind();
    };
    const refreshControls=async()=>{
      const [nextControl,nextEffective]=await Promise.all([
        rpc(sb,'platform_get_business_control_v94',{p_business:firmId(firm)}),
        rpc(sb,'platform_get_effective_modules_v94',{p_business:firmId(firm),p_branch:null})
      ]);
      control=asObject(nextControl);effective=asObject(nextEffective);
      if(body.isConnected)renderBody();
    };
    const bind=()=>{
      body.querySelectorAll('[data-enterprise-branch]').forEach(button=>button.onclick=()=>{
        const branch=button.dataset.enterpriseBranch;
        close();
        renderEnterprise(context,{...filters,businesses:[firmId(firm)],branch,search:''});
      });
      const more=body.querySelector('#enterpriseCustomersMore');
      if(more)more.onclick=async()=>{
        more.disabled=true;more.textContent='Loading…';
        try{
          const next=await fetchEnterpriseCustomerPage(sb,scopedFilters,snapshot,page.next_cursor);
          customers=customers.concat(asArray(next,['customers']));
          page=asObject(next.pagination);
          renderBody();
        }catch(error){
          more.disabled=false;more.textContent='Try loading again';
          more.title=error?.message||'Customer page unavailable';
        }
      };
      body.querySelectorAll('[data-business-approval]').forEach(button=>{
        button.onclick=()=>businessApprovalModal(firm,button.dataset.businessApproval,control,context,refreshControls);
      });
      body.querySelectorAll('[data-module-control]').forEach(button=>{
        button.onclick=()=>moduleControlModal(firm,effective,context,refreshControls,{
          branchId:button.dataset.branchId||null,moduleKey:button.dataset.moduleControl||''
        });
      });
      body.querySelectorAll('[data-manage-branch]').forEach(button=>{
        button.onclick=async()=>{
          button.disabled=true;
          try{
            const branchEffective=asObject(await rpc(sb,'platform_get_effective_modules_v94',{
              p_business:firmId(firm),p_branch:button.dataset.manageBranch
            }));
            moduleControlModal(firm,branchEffective,context,refreshControls,{branchId:button.dataset.manageBranch});
          }catch(error){
            button.disabled=false;CUI.announce(error.message||'Branch policy could not be loaded.',{assertive:true});
          }
        };
      });
      body.querySelector('[data-catalogue-intelligence]')?.addEventListener('click',async event=>{
        const button=event.currentTarget,enable=button.dataset.catalogueIntelligence==='enable';
        if(!globalObject.confirm(`${enable?'Enable':'Disable'} item-level intelligence for ${firm.name}?`))return;
        button.disabled=true;
        try{
          await rpc(sb,'platform_set_catalogue_intelligence_v94',{
            p_business:firmId(firm),p_enabled:enable,
            p_reason:enable?'Enabled for catalogue-first sales and monthly advisory reporting.':'Disabled by super-admin.',
            p_expected_version:asObject(control.catalogue_intelligence).version??null
          });
          await refreshControls();CUI.announce(`Item-level intelligence ${enable?'enabled':'disabled'}.`);
        }catch(error){button.disabled=false;CUI.announce(error.message||'Setting could not be updated.',{assertive:true})}
      });
    };
    Promise.all([
      fetchEnterpriseCustomerPage(sb,scopedFilters,snapshot),
      rpc(sb,'platform_get_business_control_v94',{p_business:firmId(firm)}),
      rpc(sb,'platform_get_effective_modules_v94',{p_business:firmId(firm),p_branch:null})
    ]).then(([payload,controlPayload,effectivePayload])=>{
      if(!body.isConnected)return;
      snapshot=snapshot||payload.snapshot_at;
      customers=asArray(payload,['customers']);page=asObject(payload.pagination);
      control=asObject(controlPayload);effective=asObject(effectivePayload);
      renderBody();
    }).catch(error=>{
      if(body.isConnected)body.innerHTML=CUI.errorState({
        title:'Firm controls unavailable',message:error?.message||'Please try again.'
      });
    });
  }
  function reportCsvRows(report,customers=[]) {
    const rows=[['record_type','firm','branch','customer','sector','currency','metric','value','from','to','snapshot_at']];
    const scope=asObject(report.scope);
    asArray(report.businesses).forEach(row=>{
      for(const key of ['net_revenue_cents','completed_transactions','active_customers','returning_customers'])
        rows.push(['business',row.name,'','',row.industry,row.currency,key,row[key]??0,scope.from,scope.to,report.snapshot_at]);
    });
    asArray(report.branches).forEach(row=>{
      for(const key of ['net_revenue_cents','completed_transactions','active_customers'])
        rows.push(['branch',row.business_name,row.name,'','',row.currency,key,row[key]??0,scope.from,scope.to,report.snapshot_at]);
    });
    customers.forEach(row=>{
      for(const key of ['net_revenue_cents','cash_collected_cents','completed_transactions','visit_count','days_since_last_purchase'])
        rows.push(['customer',row.business_name,'',row.full_name,row.industry,row.currency,key,row[key]??'',scope.from,scope.to,report.snapshot_at]);
    });
    asArray(report.insights).forEach(row=>rows.push([
      'insight','','','','','',row.title,`${row.priority}: ${row.recommendation}`,scope.from,scope.to,report.snapshot_at
    ]));
    return rows;
  }
  function reportHtml(report,CUI,customers=[],customerPage={},includeActions=true) {
    const summary=asObject(report.summary),scope=asObject(report.scope);
    const insights=asArray(report.insights),monthly=asArray(report.monthly_trend);
    const businesses=asArray(report.businesses),branches=asArray(report.branches);
    const currencies=asArray(report.summary_by_currency);
    const single=summary.currency_mode==='single'&&summary.currency;
    const moneyCards=single?[
      ['Net revenue',currency(summary.net_revenue_cents,summary.currency),'reports'],
      ['Cash collected',currency(summary.cash_collected_cents,summary.currency),'reports']
    ]:[['Currency groups',currencies.length,'reports']];
    return `<div class="card platform-report-sheet" id="enterpriseReportSheet">
      <div class="platform-list-row"><div><h2>Business improvement report</h2><p class="muted small">${escapeHtml(scope.from)} to ${escapeHtml(scope.to)} · ${escapeHtml(scope.firm_count??0)} firm${Number(scope.firm_count)===1?'':'s'} · ${escapeHtml(scope.branch_count??0)} branch${Number(scope.branch_count)===1?'':'es'}${scope.search?` · search “${escapeHtml(scope.search)}”`:''}</p><p class="muted small">Snapshot ${escapeHtml(dateTime(report.snapshot_at))}. Money remains separated by currency.</p></div>${includeActions?'<div class="platform-actions no-print"><button type="button" class="btn ghost sm" id="enterpriseReportCsv">Download complete CSV</button><button type="button" class="btn ghost sm" id="enterpriseReportPrint">Print report</button></div>':''}</div>
      <section class="platform-kpis" aria-label="Report summary">${[
        ...moneyCards,
        ['Returning rate',`${Number(summary.returning_rate_pct||0).toFixed(1)}%`,'retention'],
        ['Active customers',summary.active_customers??0,'customers']
      ].map(([label,value,icon])=>`<article class="platform-kpi"><div class="platform-kpi-label">${CUI.icon(icon,{size:17})}<span>${escapeHtml(label)}</span></div><div class="platform-kpi-value">${escapeHtml(value)}</div></article>`).join('')}</section>
      ${currencies.length?`<section class="platform-detail-section"><h3>Money by currency</h3>${CUI.table({caption:'Report money by currency',headers:['Currency','Net revenue','Cash collected','Transactions','Active customers','Returning rate'],rows:currencies.map(row=>[
        escapeHtml(row.currency),currency(row.net_revenue_cents,row.currency),currency(row.cash_collected_cents,row.currency),String(row.completed_transactions??0),String(row.active_customers??0),`${Number(row.returning_rate_pct||0).toFixed(1)}%`
      ])})}</section>`:''}
      <section class="platform-report-insights"><h3>Evidence-backed priorities</h3>${insights.map(insight=>`<article class="platform-insight"><div>${CUI.status(plainLabel(insight.priority),insight.priority==='high'?'no':insight.priority==='medium'?'new':'off')}</div><div><b>${escapeHtml(insight.title)}</b><p>${escapeHtml(insight.recommendation)}</p><small>${escapeHtml(JSON.stringify(insight.evidence||{}))}</small></div></article>`).join('')}</section>
      <section class="platform-detail-section"><h3>Monthly trend</h3>${monthly.length?CUI.table({caption:'Monthly report trend',headers:['Month','Currency','Net revenue','Transactions','Active customers'],rows:monthly.map(row=>[escapeHtml(row.month_start),escapeHtml(row.currency),currency(row.net_revenue_cents,row.currency),String(row.transactions??0),String(row.active_customers??0)])}):''}</section>
      <div class="platform-detail-grid">
        ${CUI.card({title:'Firm comparison',body:businesses.length?CUI.table({caption:'Firm report comparison',headers:['Firm','Sector','Currency','Net revenue','Transactions','Active customers'],rows:businesses.map(row=>[escapeHtml(row.name),escapeHtml(plainLabel(row.industry)),escapeHtml(row.currency),currency(row.net_revenue_cents,row.currency),String(row.completed_transactions??0),String(row.active_customers??0)])}):'<p class="muted">No firm rows.</p>'})}
        ${CUI.card({title:'Branch comparison',body:branches.length?CUI.table({caption:'Branch report comparison',headers:['Firm','Branch','Currency','Net revenue','Customers'],rows:branches.map(row=>[escapeHtml(row.business_name),escapeHtml(row.name),escapeHtml(row.currency),currency(row.net_revenue_cents,row.currency),String(row.active_customers??0)])}):'<p class="muted">No branch rows.</p>'})}
      </div>
      <section class="platform-detail-section"><div class="platform-list-row"><h3>Customer detail</h3><span class="muted small">${escapeHtml(customerPage.total_customers??report.customer_total??customers.length)} total; preview is snapshot-paged</span></div>${customers.length?CUI.table({caption:'Customer report detail',headers:['Firm','Customer','Currency','Revenue','Cash','Visits','Lifetime last purchase','Returning'],rows:customers.map(row=>[escapeHtml(row.business_name),escapeHtml(row.full_name),escapeHtml(row.currency),currency(row.net_revenue_cents,row.currency),currency(row.cash_collected_cents,row.currency),String(row.visit_count??0),escapeHtml(dateTime(row.last_purchase_at)),row.returning_customer?'Yes':'No'])}):'<p class="muted">No customer rows in this scope.</p>'}</section>
      <footer class="platform-report-method"><b>Methodology</b><p>${escapeHtml(report.methodology?.revenue||'')}</p><p>${escapeHtml(report.methodology?.returning_customer||'')} The returning-rate denominator is active customers in this period.</p><p>${escapeHtml(report.methodology?.lapsed_customer||'')}</p></footer>
    </div>`;
  }
  function consultativeIntelligenceHtml(report,affinity,recommendations,CUI) {
    const kpis=asObject(report.kpis),intelligence=asObject(report.customer_intelligence);
    const quality=asObject(report.data_quality),pairs=asArray(affinity.pairs);
    const actions=asArray(recommendations.recommendations);
    const confidence=quality.confidence||quality.status||'not_enough_data';
    const cohortRows=asArray(intelligence.cohorts||intelligence.segments||intelligence.customer_groups);
    return `<section class="card platform-report-sheet platform-consultative-report" aria-labelledby="consultativeReportTitle">
      <div class="platform-list-row"><div><h2 id="consultativeReportTitle">Monthly consultant brief</h2>
        <p class="muted small">Item-level customer intelligence for this exact firm, branch and date scope. Every recommendation is tied to returned evidence.</p></div>
        ${CUI.status(plainLabel(confidence),confidence==='high'||confidence==='ready'?'ok':confidence==='medium'?'new':'off')}
      </div>
      <section class="platform-kpis" aria-label="Consultant brief KPIs">${[
        ['Customers',kpis.customer_count??kpis.active_customers??0,'customers'],
        ['Returning rate',`${Number(kpis.returning_rate_pct||0).toFixed(1)}%`,'retention'],
        ['Transactions',kpis.transaction_count??kpis.completed_transactions??0,'till'],
        ['Revenue',currency(kpis.net_revenue_cents??kpis.revenue_cents??0,kpis.currency||'SGD'),'reports']
      ].map(([label,value,icon])=>`<article class="platform-kpi"><div class="platform-kpi-label">${CUI.icon(icon,{size:17})}<span>${escapeHtml(label)}</span></div><div class="platform-kpi-value">${escapeHtml(value)}</div></article>`).join('')}</section>
      <div class="platform-detail-grid">
        ${CUI.card({title:'Customer groups',description:'Use these groups to plan specific monthly actions, not generic campaigns.',body:cohortRows.length?CUI.table({
          caption:'Customer group performance',headers:['Group','Customers','Orders','Revenue','Return rate'],
          rows:cohortRows.map(row=>[
            escapeHtml(row.label||plainLabel(row.cohort||row.segment||row.group_key)),
            String(row.customer_count??row.customers??0),String(row.order_count??row.transactions??0),
            currency(row.revenue_cents??row.net_revenue_cents??0,row.currency||kpis.currency||'SGD'),
            `${Number(row.returning_rate_pct||0).toFixed(1)}%`
          ])
        }):'<p class="muted small">The selected scope does not yet have enough customer-group data.</p>'})}
        ${CUI.card({title:'Products bought with services',description:'Attach rate is calculated only from canonical, non-reversed sale lines.',body:affinity.enabled===false
          ?'<p class="muted small">Item-level intelligence is disabled for this firm.</p>'
          :pairs.length?CUI.table({
            caption:'Product and service affinity',headers:['Service','Product','Together','Attach rate','Units','Paired revenue'],
            rows:pairs.map(row=>[
              escapeHtml(row.service_name||'—'),escapeHtml(row.product_name||'—'),
              String(row.orders_together??0),`${Number(row.attach_rate_pct||0).toFixed(1)}%`,
              String(row.product_units??0),currency(row.paired_revenue_cents??0,kpis.currency||'SGD')
            ])
          }):'<p class="muted small">No reliable product/service pair is available in this scope yet.</p>'})}
      </div>
      <section class="platform-report-insights"><h3>Consultative action plan</h3>${actions.length?actions.map(action=>`
        <article class="platform-insight"><div>${CUI.status(plainLabel(action.priority),action.priority==='high'?'no':action.priority==='medium'?'new':'off')}</div>
          <div><b>${escapeHtml(action.title)}</b><p>${escapeHtml(action.recommended_action)}</p>
          <small>${escapeHtml(action.category?`${plainLabel(action.category)} · `:'')}${escapeHtml(JSON.stringify(action.evidence||{}))}</small></div>
        </article>`).join(''):'<div class="platform-route-note"><b>No recommendation claimed</b><p class="small">Nestly suppresses advice when the exact scope has insufficient or unreliable data.</p></div>'}</section>
      <footer class="platform-report-method"><b>Data quality</b><p>${escapeHtml(quality.message||quality.reason||'Recommendations are suppressed below the configured evidence threshold.')}</p></footer>
    </section>`;
  }
  async function renderEnterpriseReport(context,filters) {
    const {main,CUI,sb}=context,host=main.querySelector('#enterpriseReportHost');
    if(!host)return;
    host.innerHTML=loading(CUI,'Detailed report','Calculating the selected enterprise scope…','reports');
    try{
      const report=asObject(await rpc(sb,'platform_generate_improvement_report_v82',{
        ...enterpriseArgs(filters)
      }));
      const customerPayload=await fetchEnterpriseCustomerPage(
        sb,filters,report.snapshot_at
      );
      if(!host.isConnected)return;
      host.innerHTML=reportHtml(report,CUI,asArray(customerPayload,['customers']),asObject(customerPayload.pagination));
      if(filters.businesses?.length===1){
        const business=filters.businesses[0];
        const [consultantReport,affinity,recommendations]=await Promise.all([
          rpc(sb,'platform_get_assigned_firm_report_v94',{
            p_business:business,p_branch:filters.branch||null,p_from:filters.from,p_to:filters.to
          }),
          rpc(sb,'platform_get_catalogue_affinity_v94',{
            p_business:business,p_branch:filters.branch||null,p_from:filters.from,p_to:filters.to,p_limit:25
          }),
          rpc(sb,'platform_get_consultative_recommendations_v94',{
            p_business:business,p_branch:filters.branch||null,p_from:filters.from,p_to:filters.to
          })
        ]);
        host.insertAdjacentHTML('beforeend',consultativeIntelligenceHtml(
          asObject(consultantReport),asObject(affinity),asObject(recommendations),CUI
        ));
      }
      host.querySelector('#enterpriseReportCsv').onclick=async event=>{
        const button=event.currentTarget;
        button.disabled=true;button.textContent='Preparing complete CSV…';
        try{
          const customers=await fetchAllEnterpriseCustomers(sb,filters,report.snapshot_at);
          downloadCsv(
            `${context.brand?.downloadPrefix||'nestly'}-enterprise-report-${filters.from}-${filters.to}.csv`,
            reportCsvRows(report,customers)
          );
          button.textContent=`Downloaded ${customers.length} customers`;
        }catch(error){
          button.disabled=false;button.textContent='Retry complete CSV';
          button.title=error?.message||'Export unavailable';
        }
      };
      host.querySelector('#enterpriseReportPrint').onclick=()=>globalObject.print();
      host.querySelector('#enterpriseReportSheet')?.scrollIntoView?.({behavior:'smooth',block:'start'});
    }catch(error){host.innerHTML=error?.platformUpdateRequired?systemUpdateRequired(CUI,'Enterprise reports'):CUI.errorState({title:'Report unavailable',message:error?.message||'Please try again.'})}
  }
  async function renderEnterprise(context,filters=enterpriseDefaults()) {
    const {main,CUI,sb,generation,isCurrent}=context;
    main.innerHTML=loading(CUI,'Enterprise data','Loading firm, branch and customer truth…','branch');
    try{
      const directory=await fetchFirmDirectoryV88(sb,filters);
      let rawPayload,resolvedScopeFilters=filters;
      if(filters.search){
        const hierarchyMatches=await fetchEnterpriseFirmPages(sb,filters);
        const resolvedIds=resolveEnterpriseSearchBusinessIds(
          directory?.items,asArray(hierarchyMatches,['firms']),filters.businesses
        );
        resolvedScopeFilters={...filters,businesses:resolvedIds,search:''};
        rawPayload=resolvedIds.length
          ?await fetchEnterpriseFirmPages(sb,resolvedScopeFilters)
          :{
            snapshot_at:directory?.snapshot_at||hierarchyMatches.snapshot_at,
            firms:[],pagination:{total_firms:0,returned_firms:0,has_more:false,next_cursor:null}
          };
      }else rawPayload=await fetchEnterpriseFirmPages(sb,filters);
      const firms=mergeFirmDirectoryData(asArray(rawPayload,['firms']),directory?.items);
      const payload={...rawPayload,firms,pagination:{
        ...asObject(rawPayload.pagination),
        total_firms:firms.length,returned_firms:firms.length
      }};
      if(generation!==renderGeneration||!main.isConnected||(isCurrent&&!isCurrent()))return;
      if(!context.enterpriseCatalog||(!filters.sector&&!filters.businesses.length&&!filters.branch&&!filters.search)){
        context.enterpriseCatalog=firms;
      }
      const catalog=context.enterpriseCatalog||firms;
      context.enterpriseSnapshot=payload.snapshot_at;
      const canGenerateReport=canAccessModule(context.access,'reports');
      main.innerHTML=enterpriseHtml(asObject(payload),CUI,filters,catalog,canGenerateReport);
      const form=main.querySelector('#enterpriseFilters'),businessSelect=main.querySelector('#enterpriseBusinesses');
      const refreshBranches=()=>{
        const ids=selectedOptions(businessSelect),branchSelect=main.querySelector('#enterpriseBranch');
        const selectedFirm=ids.length===1?catalog.find(row=>firmId(row)===ids[0]):null;
        branchSelect.disabled=ids.length!==1;
        branchSelect.innerHTML=`<option value="">Whole firm</option>${asArray(selectedFirm?.branches).map(branch=>`<option value="${escapeHtml(branch.branch_id)}">${escapeHtml(branch.name)}</option>`).join('')}`;
      };
      businessSelect.onchange=refreshBranches;
      form.onsubmit=event=>{
        event.preventDefault();
        const businesses=selectedOptions(businessSelect);
        renderEnterprise(context,{
          sector:main.querySelector('#enterpriseSector').value,
          businesses,
          branch:businesses.length===1?main.querySelector('#enterpriseBranch').value:'',
          search:main.querySelector('#enterpriseSearch').value.trim(),
          from:main.querySelector('#enterpriseFrom').value,
          to:main.querySelector('#enterpriseTo').value
        });
      };
      main.querySelector('#enterpriseClear').onclick=()=>renderEnterprise(context,enterpriseDefaults());
      const reportButton=main.querySelector('#enterpriseGenerateReport');
      if(reportButton&&firms.length)reportButton.onclick=()=>renderEnterpriseReport(context,resolvedScopeFilters);
      main.querySelectorAll('[data-enterprise-firm]').forEach(button=>{
        button.onclick=()=>{
          const firm=firms.find(row=>firmId(row)===button.dataset.enterpriseFirm);
          if(firm)openEnterpriseFirm(firm,context,{...filters,search:''});
        };
      });
      CUI.focusRoute(main);
    }catch(error){showError(main,error,CUI,'Enterprise data')}
  }

  function reportsPageHtml(CUI,filters,catalog) {
    const branches=enterpriseBranchOptions(filters,catalog);
    return `${CUI.pageHeader({
      title:'Enterprise reports',
      subtitle:'Build one snapshot-backed report across customer performance, SME acquisition, onboarding and subscription billing.',
      iconName:'reports'
    })}
      <form class="card platform-enterprise-filters" id="platformReportFilters">
        <div class="platform-enterprise-filter-grid">
          ${CUI.field({id:'platformReportSearch',label:'Search inside scope',type:'search',value:filters.search,placeholder:'Firm, branch or customer'})}
          ${CUI.field({id:'platformReportSector',label:'Sector',control:'select',options:enterpriseSectors.map(([value,label])=>({value,label,selected:value===filters.sector}))})}
          <div class="cui-field platform-enterprise-firms"><label for="platformReportBusinesses">Firms <span class="muted small">(one or more)</span></label>
            <select id="platformReportBusinesses" multiple size="5">${catalog.map(firm=>`<option value="${escapeHtml(firmId(firm))}"${filters.businesses.includes(firmId(firm))?' selected':''}>${escapeHtml(firm.name)} · ${escapeHtml(plainLabel(firm.industry))}</option>`).join('')}</select>
            <p class="muted small">No selection means every firm in the selected sector.</p>
          </div>
          <div class="cui-field"><label for="platformReportBranch">Branch</label><select id="platformReportBranch"${filters.businesses.length===1?'':' disabled'}>
            <option value="">Whole firm</option>${branches.map(branch=>`<option value="${escapeHtml(branch.branch_id)}"${branch.branch_id===filters.branch?' selected':''}>${escapeHtml(branch.name)}</option>`).join('')}
          </select><p class="muted small">${filters.businesses.length===1?'Report one branch or the whole firm.':'Select one firm to report an individual branch.'}</p></div>
          ${CUI.field({id:'platformReportFrom',label:'From',type:'date',value:filters.from,required:true})}
          ${CUI.field({id:'platformReportTo',label:'To',type:'date',value:filters.to,required:true})}
        </div>
        <div class="platform-actions"><button class="btn" type="submit">${CUI.icon('reports',{size:17})}<span>Generate report</span></button><button type="button" class="btn ghost" id="platformReportReset">Reset</button></div>
      </form>
      <div class="platform-route-note platform-status-note">${CUI.icon('info',{size:19})}<div><b>Explicit scope, no silent blending</b><p class="small">Firm performance respects sector, firm, branch, search and date. SME pipeline analytics respects date and operator visibility; the report labels that separate scope. Currency totals remain separated.</p></div></div>
      <section id="platformCrossDomainReport" class="platform-report-host" aria-live="polite">${CUI.emptyState({iconName:'reports',title:'Choose a reporting scope',body:'Generate a report to compare customer performance, pipeline conversion and billing exceptions.'})}</section>`;
  }
  function analyticsReportRows(analytics) {
    const summary=asObject(analytics.summary),scope=asObject(analytics.scope);
    const rows=[['record_type','scope','name','group','metric','value','currency','from','to','snapshot_at']];
    Object.entries(summary).forEach(([metric,value])=>rows.push(['sme_summary','all_prospects','SME pipeline','summary',metric,value,metric.endsWith('_cents')?'SGD':'',scope.from,scope.to,analytics.snapshot_at]));
    asArray(analytics.stages).forEach(stage=>['current_count','entries','median_age_days'].forEach(metric=>rows.push(['sme_stage','all_prospects',stage.label||stage.stage_key,stage.stage_key,metric,stage[metric]??'','',scope.from,scope.to,analytics.snapshot_at])));
    asArray(analytics.source_page).forEach(source=>['leads','converted'].forEach(metric=>rows.push(['sme_source','all_prospects',plainLabel(source.source_type),source.source_type,metric,source[metric]??0,'',scope.from,scope.to,analytics.snapshot_at])));
    return rows;
  }
  function billingReportRows(rows,reconciliation,filters,snapshot) {
    const output=[['record_type','scope','name','group','metric','value','currency','from','to','snapshot_at']];
    rows.forEach(row=>[
      ['subscription_status',row.status],['payment_status',row.payment_status],
      ['period_subtotal_cents',row.period_subtotal_cents],['period_tax_cents',row.period_tax_cents],
      ['period_total_cents',row.period_total_cents],['failed_event_count',row.failed_event_count],
      ['next_payment_at',row.next_payment_at]
    ].forEach(([metric,value])=>output.push(['billing','selected_firms',row.business_name,row.business_id,metric,value??'',row.currency||'',filters.from,filters.to,snapshot])));
    asArray(reconciliation.items).forEach(item=>output.push(['reconciliation','latest_run',item.provider_object_id||item.object_type,item.business_id,item.result,JSON.stringify(item.detail||{}),'',filters.from,filters.to,snapshot]));
    return output;
  }
  function crossDomainReportHtml({
    report,customers,customerPage,analytics,billing,reconciliation,
    analyticsAvailable=false,billingAvailable=false
  },CUI,filters) {
    const summary=asObject(report.summary),crm=asObject(analytics.summary);
    const billingExceptions=billing.filter(row=>row.status==='past_due'||row.payment_status==='past_due'||Number(row.failed_event_count||0)>0);
    const runs=asArray(reconciliation.runs),items=asArray(reconciliation.items);
    const latestRun=runs[0]||{};
    const reportScope=asObject(report.scope),crmScope=asObject(analytics.scope);
    return `<article class="card platform-report-sheet" id="platformCrossDomainReportSheet">
      <header class="platform-list-row"><div><h2>Enterprise performance report</h2><p class="muted small">${escapeHtml(reportScope.from||filters.from)} to ${escapeHtml(reportScope.to||filters.to)} · snapshot ${escapeHtml(dateTime(report.snapshot_at))}</p></div><div class="platform-actions no-print"><button type="button" class="btn ghost sm" data-cross-report-csv>Download complete CSV</button><button type="button" class="btn ghost sm" data-cross-report-print>Print / PDF</button></div></header>
      <section class="platform-kpis" aria-label="Cross-domain report summary">${[
        ['Active customers',summary.active_customers??0,'customers'],
        ['Returning rate',`${Number(summary.returning_rate_pct||0).toFixed(1)}%`,'retention'],
        ...(analyticsAvailable?[
          ['Pipeline leads',crm.leads_created??0,'setup'],
          ['Deals won',crm.won??0,'check'],
          ['Activated',crm.activated??0,'branch']
        ]:[]),
        ...(billingAvailable?[['Billing exceptions',billingExceptions.length,'info']]:[])
      ].map(([label,value,icon])=>`<article class="platform-kpi"><div class="platform-kpi-label">${CUI.icon(icon,{size:17})}<span>${escapeHtml(label)}</span></div><div class="platform-kpi-value">${escapeHtml(value)}</div></article>`).join('')}</section>
      <section class="platform-detail-section"><h3>Customer and firm performance</h3>${reportHtml(report,CUI,customers,customerPage,false).replace('id="enterpriseReportSheet"','')}</section>
      ${analyticsAvailable?`<section class="platform-detail-section"><div class="platform-list-row"><div><h3>SME acquisition and onboarding</h3><p class="muted small">All visible prospects · ${escapeHtml(crmScope.from||filters.from)} to ${escapeHtml(crmScope.to||filters.to)}. Firm/branch filters do not apply to this prospect pipeline contract.</p></div></div>
        <div class="platform-detail-grid">
          ${CUI.card({title:'Stage performance',body:asArray(analytics.stages).length?CUI.table({caption:'SME stage performance',headers:['Stage','Current','Entries','Median age (days)'],rows:asArray(analytics.stages).map(stage=>[escapeHtml(stage.label||plainLabel(stage.stage_key)),String(stage.current_count??0),String(stage.entries??0),Number(stage.median_age_days||0).toFixed(1)])}):'<p class="muted small">No stage data.</p>'})}
          ${CUI.card({title:'Source conversion',body:asArray(analytics.source_page).length?CUI.table({caption:'SME source conversion',headers:['Source','Leads','Converted','Rate'],rows:asArray(analytics.source_page).map(source=>[escapeHtml(plainLabel(source.source_type)),String(source.leads??0),String(source.converted??0),`${Number(source.leads?Number(source.converted||0)*100/Number(source.leads):0).toFixed(1)}%`])}):'<p class="muted small">No source attribution data.</p>'})}
        </div>
        ${asArray(analytics.loss_reasons).length?CUI.card({title:'Loss reasons',body:CUI.table({caption:'Loss reasons',headers:['Reason','Prospects'],rows:asArray(analytics.loss_reasons).map(row=>[escapeHtml(plainLabel(row.reason_code)),String(row.count??0)])})}):''}
      </section>`:'<div class="platform-route-note"><b>SME acquisition and onboarding omitted</b><p class="small">This account does not have Onboarding access. The customer and firm report above remains complete for the selected scope.</p></div>'}
      ${billingAvailable?`<section class="platform-detail-section"><div class="platform-list-row"><div><h3>Subscription billing and reconciliation</h3><p class="muted small">${billing.length} subscription records in the selected firm scope. GST remains visible and is not treated as commissionable revenue.</p></div>${latestRun.id?CUI.status(plainLabel(latestRun.status),latestRun.status==='completed'?'ok':'off'):CUI.status('No reconciliation run','off')}</div>
        ${billing.length?CUI.table({caption:'Selected firm billing',headers:['Firm','Subscription','Payment','Cadence','Subtotal','GST','Total','Next payment','Failures'],rows:billing.map(row=>[
          escapeHtml(row.business_name),CUI.status(row.status||'—',statusTone(row.status)),CUI.status(row.payment_status||'—',row.payment_status==='paid'?'ok':row.payment_status==='past_due'?'no':'off'),escapeHtml(plainLabel(row.cadence)),currency(row.period_subtotal_cents,row.currency),currency(row.period_tax_cents,row.currency),currency(row.period_total_cents,row.currency),escapeHtml(dateTime(row.next_payment_at)),String(row.failed_event_count||0)
        ])}):'<p class="muted small">No billing rows in this firm scope.</p>'}
        <div class="platform-detail-grid">
          ${CUI.card({title:'Billing exception queue',description:billingExceptions.length?`${billingExceptions.length} firms need attention.`:'No firm-level payment exceptions.',body:billingExceptions.length?billingExceptions.map(row=>`<div class="platform-action-item"><div><b>${escapeHtml(row.business_name)}</b><p class="muted small">${escapeHtml(plainLabel(row.payment_status||row.status))} · ${escapeHtml(dateTime(row.next_payment_at))}</p></div>${CUI.status(`${Number(row.failed_event_count||0)} failures`,'no')}</div>`).join(''):'<p class="muted small">No overdue or failed subscription records.</p>'})}
          ${CUI.card({title:'Latest reconciliation',description:latestRun.started_at?`${dateTime(latestRun.started_at)} · ${plainLabel(latestRun.run_mode)}`:'No reconciliation run was returned.',body:items.length?items.map(item=>`<div class="platform-action-item"><div><b>${escapeHtml(plainLabel(item.object_type))}</b><p class="muted small">${escapeHtml(item.provider_object_id||'Provider object')}</p></div>${CUI.status(plainLabel(item.result),item.result==='matched'?'ok':'no')}</div>`).join(''):'<p class="muted small">No mismatch items in the latest returned run.</p>'})}
        </div>
      </section>`:'<div class="platform-route-note"><b>Subscription billing omitted</b><p class="small">This account does not have Billing access. No billing or reconciliation reader was called.</p></div>'}
    </article>`;
  }
  async function renderCrossDomainReport(context,filters) {
    const {main,CUI,sb}=context,host=main.querySelector('#platformCrossDomainReport');
    if(!host)return;
    host.innerHTML=loading(CUI,'Enterprise report','Building firm, customer, pipeline and billing sections…','reports');
    try{
      const sectionAccess=reportSectionAccess(context.access);
      const [report,customerPayload,analytics,billingPayload,reconciliationRuns]=await Promise.all([
        rpc(sb,'platform_generate_improvement_report_v82',enterpriseArgs(filters)),
        fetchEnterpriseCustomerPage(sb,filters,null),
        sectionAccess.onboarding
          ?rpc(sb,'platform_get_sme_analytics_v86',{p_from:filters.from,p_to:filters.to,p_snapshot_at:null,p_consultant:null,p_limit:200,p_after_source:null})
          :Promise.resolve(null),
        sectionAccess.billing?rpc(sb,'platform_get_billing_v89',{p_business:null,p_limit:250}):Promise.resolve(null),
        sectionAccess.billing?rpc(sb,'platform_get_billing_reconciliation_v89',{p_run:null,p_limit:50}):Promise.resolve(null)
      ]);
      const reportObject=asObject(report),allowedIds=new Set(asArray(reportObject.businesses).map(firmId));
      const billing=asArray(billingPayload).filter(row=>!allowedIds.size||allowedIds.has(String(row.business_id)));
      const runPayload=asObject(reconciliationRuns),latestRun=asArray(runPayload.runs)[0];
      const reconciliation=sectionAccess.billing&&latestRun?.id
        ?asObject(await rpc(sb,'platform_get_billing_reconciliation_v89',{p_run:latestRun.id,p_limit:50}))
        :runPayload;
      const payload={
        report:reportObject,customers:asArray(customerPayload,['customers']),
        customerPage:asObject(customerPayload.pagination),analytics:asObject(analytics),
        billing,reconciliation,analyticsAvailable:sectionAccess.onboarding,
        billingAvailable:sectionAccess.billing
      };
      if(!host.isConnected)return;
      host.innerHTML=crossDomainReportHtml(payload,CUI,filters);
      if(filters.businesses?.length===1){
        const business=filters.businesses[0];
        const [consultantReport,affinity,recommendations]=await Promise.all([
          rpc(sb,'platform_get_assigned_firm_report_v94',{
            p_business:business,p_branch:filters.branch||null,p_from:filters.from,p_to:filters.to
          }),
          rpc(sb,'platform_get_catalogue_affinity_v94',{
            p_business:business,p_branch:filters.branch||null,p_from:filters.from,p_to:filters.to,p_limit:25
          }),
          rpc(sb,'platform_get_consultative_recommendations_v94',{
            p_business:business,p_branch:filters.branch||null,p_from:filters.from,p_to:filters.to
          })
        ]);
        host.insertAdjacentHTML('beforeend',consultativeIntelligenceHtml(
          asObject(consultantReport),asObject(affinity),asObject(recommendations),CUI
        ));
      }
      host.querySelector('[data-cross-report-print]').onclick=()=>globalObject.print();
      host.querySelector('[data-cross-report-csv]').onclick=async event=>{
        const button=event.currentTarget;button.disabled=true;button.textContent='Preparing complete CSV…';
        try{
          const customers=await fetchAllEnterpriseCustomers(sb,filters,reportObject.snapshot_at);
          const legacy=reportCsvRows(reportObject,customers),header=legacy[0];
          const extendedHeader=['record_type','scope','name','group','metric','value','currency','from','to','snapshot_at'];
          const convertLegacy=row=>[row[0],row[1]||row[2]||row[3]||'',row[3]||row[1]||'',row[4]||'',row[6],row[7],row[5],row[8],row[9],row[10]];
          downloadCsv(`${context.brand?.downloadPrefix||'nestly'}-enterprise-cross-domain-${filters.from}-${filters.to}.csv`,[
            extendedHeader,...legacy.slice(1).map(convertLegacy),
            ...(sectionAccess.onboarding?analyticsReportRows(asObject(analytics)).slice(1):[]),
            ...(sectionAccess.billing?billingReportRows(billing,reconciliation,filters,reportObject.snapshot_at).slice(1):[])
          ]);
          button.textContent=`Downloaded ${customers.length} customer rows`;
        }catch(error){button.disabled=false;button.textContent='Retry complete CSV';button.title=error.message}
      };
      host.querySelector('#platformCrossDomainReportSheet')?.scrollIntoView?.({behavior:'smooth',block:'start'});
    }catch(error){host.innerHTML=error.platformUpdateRequired?systemUpdateRequired(CUI,'Enterprise reports'):CUI.errorState({title:'Report unavailable',message:error.message||'Please try again.'})}
  }
  async function renderPlatformReports(context,filters=enterpriseDefaults()) {
    const {main,CUI,sb}=context;
    main.innerHTML=loading(CUI,'Enterprise reports','Loading reporting dimensions…','reports');
    try{
      if(!context.enterpriseCatalog)context.enterpriseCatalog=asArray(await fetchEnterpriseFirmPages(sb,enterpriseDefaults()),['firms']);
      const catalog=context.enterpriseCatalog;
      main.innerHTML=reportsPageHtml(CUI,filters,catalog);
      const form=main.querySelector('#platformReportFilters'),businessSelect=main.querySelector('#platformReportBusinesses');
      businessSelect.onchange=()=>{
        const ids=selectedOptions(businessSelect),branch=main.querySelector('#platformReportBranch');
        const firm=ids.length===1?catalog.find(row=>firmId(row)===ids[0]):null;
        branch.disabled=ids.length!==1;
        branch.innerHTML=`<option value="">Whole firm</option>${asArray(firm?.branches).map(row=>`<option value="${escapeHtml(row.branch_id)}">${escapeHtml(row.name)}</option>`).join('')}`;
      };
      form.onsubmit=event=>{
        event.preventDefault();
        const businesses=selectedOptions(businessSelect),next={
          search:main.querySelector('#platformReportSearch').value.trim(),
          sector:main.querySelector('#platformReportSector').value,businesses,
          branch:businesses.length===1?main.querySelector('#platformReportBranch').value:'',
          from:main.querySelector('#platformReportFrom').value,to:main.querySelector('#platformReportTo').value
        };
        renderPlatformReports(context,next).then(()=>renderCrossDomainReport(context,next));
      };
      main.querySelector('#platformReportReset').onclick=()=>renderPlatformReports(context,enterpriseDefaults());
      CUI.focusRoute(main);
    }catch(error){showError(main,error,CUI,'Enterprise reports')}
  }

  function prospectCompany(item) {
    return item.company_name||item.legal_name||item.trading_name
      ||item.company?.name||item.company?.legal_name||item.company?.trading_name
      ||item.name||'Unnamed prospect';
  }
  function prospectContact(item) {
    return item.primary_contact_name||item.primary_contact?.full_name
      ||item.primary_contact?.name||item.contact_name||item.primary_contact?.email
      ||item.boss_name||item.boss_email
      ||'No primary contact';
  }
  function prospectStage(item) {
    return item.source_stage_key||item.current_stage_key||item.stage_key||item.stage
      ||item.current_stage||(item.lane_key==='case_won'?'activated':item.lane_key)||'unmapped';
  }
  function prospectVersion(item) {
    return Number(item.version??item.lock_version??item.prospect_version??0);
  }
  function prospectValue(item,...paths) {
    for(const path of paths){
      const value=path.split('.').reduce((current,key)=>current?.[key],item);
      if(value!==undefined&&value!==null&&value!=='')return value;
    }
    return'';
  }
  function prospectSource(item) {
    return prospectValue(item,'source_name','first_touch_source_name','source.source_name',
      'source.source_system','source_type','source.source_type')||'Source not recorded';
  }
  function prospectFit(item) {
    return prospectValue(item,'qualification_status','fit_level','fit','qualification.status',
      'qualification.fit_level')||'unqualified';
  }
  function prospectTags(item) {
    const tags=asArray(item.tags);
    return tags.map(tag=>typeof tag==='string'?tag:(tag.label||tag.tag_key||tag.name)).filter(Boolean);
  }
  function dayDelta(value,now=Date.now()) {
    const time=new Date(value||'').getTime();
    return Number.isFinite(time)?Math.floor((now-time)/86400000):null;
  }
  function relativeActivity(value,{future=false}={}) {
    if(!value)return future?'No next action':'No activity';
    const time=new Date(value).getTime();
    if(!Number.isFinite(time))return String(value);
    const days=Math.round((time-Date.now())/86400000);
    if(days===0)return'Today';
    if(days===1)return'Tomorrow';
    if(days===-1)return'Yesterday';
    if(days>1)return`In ${days} days`;
    return`${Math.abs(days)} days ago`;
  }
  function onboardingPercent(item) {
    const summary=asObject(item.onboarding_summary);
    if(Number.isFinite(Number(item.onboarding_completion_percent)))return Number(item.onboarding_completion_percent);
    if(summary.mandatoryTotal)return Math.round(Number(summary.mandatoryFulfilled||0)*100/Number(summary.mandatoryTotal));
    return null;
  }
  function prospectWarningFlags(item) {
    const flags=asArray(item.data_quality_flags).map(flag=>typeof flag==='string'?flag:(flag.flag_code||flag.code));
    if(item.duplicate_status&&item.duplicate_status!=='clear')flags.push('possible_duplicate');
    if(!prospectValue(item,'registration_number','company.registration_number','uen'))flags.push('missing_registration');
    if(item.contact_basis_status==='missing'||item.missing_consent===true)flags.push('missing_contact_basis');
    if(item.onboarding_status==='blocked'||asObject(item.onboarding_summary).blocked===true)flags.push('blocked_onboarding');
    return [...new Set(flags.filter(Boolean))];
  }
  function onboardingFacts(payload) {
    const onboarding=asObject(payload),checklist=asObject(onboarding.checklist);
    const items=asArray(onboarding.items);
    const mandatory=items.filter(item=>item.mandatory===true);
    const fulfilled=mandatory.filter(item=>['satisfied','waived'].includes(item.status));
    const blockedItems=items.filter(item=>item.status==='blocked');
    return {
      status:checklist.status||'',
      version:Number(checklist.version||0),
      mandatoryTotal:mandatory.length,
      mandatoryFulfilled:fulfilled.length,
      blockedItems,
      blocked:Boolean(checklist.blocked_at)||blockedItems.length>0,
      ready:checklist.status==='ready',
      activated:checklist.status==='activated'
    };
  }
  function onboardingTone(status) {
    return ['ready','activated'].includes(status)?'ok':status==='blocked'?'no':status==='in_progress'?'new':'off';
  }
  function mergeFirmOnboardingItems(directoryItems,prospects) {
    const prospectsById=new Map(prospects.map(item=>[
      String(item.prospect_id||item.id||''),item
    ]).filter(([id])=>id));
    return asArray(directoryItems).map(row=>{
      const prospectId=String(row.prospect_id||''),base=asObject(prospectsById.get(prospectId));
      const sourceStage=row.source_stage_key||base.current_stage_key||base.stage_key||base.stage||'';
      return {
        ...row,...base,
        platform_row_id:row.row_id||null,
        id:base.id||row.prospect_id||row.row_id||row.business_id,
        prospect_id:row.prospect_id||base.prospect_id||null,
        business_id:row.business_id||base.business_id||base.converted_business_id||null,
        converted_business_id:base.converted_business_id||row.business_id||null,
        company_name:base.company_name||row.name||row.legal_name||'Unnamed firm',
        legal_name:base.legal_name||row.legal_name||row.name||'',
        registration_number:base.registration_number||row.registration_number||'',
        primary_contact_name:base.primary_contact_name||row.boss_name||'',
        primary_contact_email:base.primary_contact_email||row.boss_email||'',
        primary_contact_phone:base.primary_contact_phone||row.boss_phone||'',
        current_stage_key:sourceStage||(row.lane_key==='case_won'?'activated':'unmapped'),
        source_stage_key:sourceStage||null,
        lane_key:row.lane_key||operationalLaneFor(base),
        lane_label:row.lane_label||'',
        onboarding_status:row.onboarding_status||base.onboarding_status||'',
        subscription_status:row.subscription_status||base.subscription_status||'',
        attention_severity:row.attention_severity||base.attention_severity||'',
        attention_due:row.attention_due??base.attention_due??false,
        next_action_at:row.next_action_at||base.next_action_at||null,
        last_activity_at:row.last_activity_at||base.last_activity_at||base.updated_at||null,
        _has_prospect_detail:Boolean(row.prospect_id||base.id||base.prospect_id)
      };
    });
  }
  async function hydrateOnboardingCards(sb,items) {
    const businessIds=[...new Set(items.map(item=>item.converted_business_id).filter(Boolean))];
    if(!businessIds.length)return items;
    const results=await Promise.allSettled(businessIds.map(businessId=>
      rpc(sb,'get_business_onboarding_v79',{p_business:businessId})
    ));
    const byBusiness=new Map();
    results.forEach((result,index)=>{
      if(result.status==='fulfilled'&&result.value)byBusiness.set(String(businessIds[index]),result.value);
    });
    return items.map(item=>{
      const onboarding=byBusiness.get(String(item.converted_business_id||''));
      if(!onboarding)return item;
      const facts=onboardingFacts(onboarding);
      return {...item,onboarding,onboarding_status:facts.status,onboarding_summary:facts};
    });
  }
  function prospectCardHtml(item,CUI,{mobile=false,canWrite=true}={}) {
    const stage=prospectStage(item),id=item.id||item.prospect_id||item.row_id||item.business_id;
    const stale=prospectIsStale(item);
    const overdue=item.next_action_overdue===true||item.overdue===true||Number(item.overdue_task_count||0)>0;
    const attentionSeverity=String(item.attention_severity||'none').toLowerCase();
    const completeness=Number(item.data_completeness_percent??item.completeness_percent??item.completeness??0);
    const summary=asObject(item.onboarding_summary);
    const onboarding=item.onboarding_status||summary.status||asObject(item.onboarding).checklist?.status||'';
    const managed=Boolean(item.converted_business_id||item.business_id)||['account_created','onboarding','activated'].includes(stage);
    const contactTitle=prospectValue(item,'primary_contact_title','primary_contact.title','primary_contact.job_title');
    const contactPhone=prospectValue(item,'primary_contact_phone','primary_contact.phone','contact_phone','boss_phone');
    const priority=String(item.priority||'normal'),fit=prospectFit(item);
    const nextAction=prospectValue(item,'next_action_at','next_activity_at');
    const stageDays=Math.max(0,dayDelta(item.stage_entered_at)??0),tags=prospectTags(item);
    const progress=onboardingPercent(item),warnings=prospectWarningFlags(item);
    const contactActions=platformContactActions(contactPhone,CUI,{compact:true});
    const canOpenDetail=item._has_prospect_detail!==false;
    const stageLabel=!canOpenDetail&&operationalLaneFor(item)==='case_won'
      ?(item.lane_label||'Website signup / live firm')
      :(prospectStages.find(option=>option.key===stage)?.label||plainLabel(stage));
    return `<article class="platform-prospect-card" draggable="false" data-prospect="${escapeHtml(id)}" data-version="${prospectVersion(item)}" data-stage="${escapeHtml(stage)}" data-lane="${escapeHtml(operationalLaneFor(item))}" data-has-prospect="${canOpenDetail?'true':'false'}" tabindex="0" role="button" aria-label="${canOpenDetail?'Open':'View firm record for'} ${escapeHtml(prospectCompany(item))}">
      <div class="platform-prospect-name">${escapeHtml(prospectCompany(item))}</div>
      <div class="platform-prospect-contact"><b>${escapeHtml(prospectContact(item))}</b>${contactTitle?`<span>${escapeHtml(contactTitle)}</span>`:''}${contactPhone?`<span>${escapeHtml(contactPhone)}</span>`:''}</div>
      <dl class="platform-card-facts">
        <div><dt>Owner</dt><dd>${escapeHtml(item.consultant_name||item.owner_name||(item.assigned_consultant_id?'Assigned':'Unassigned'))}</dd></div>
        ${canOpenDetail
          ?`<div><dt>Priority / fit</dt><dd>${escapeHtml(`${plainLabel(priority)} · ${plainLabel(fit)}`)}</dd></div>`
          :`<div><dt>Sector</dt><dd>${escapeHtml(plainLabel(item.sector_key||item.industry))}</dd></div>`}
        ${canOpenDetail
          ?`<div><dt>Next action</dt><dd>${escapeHtml(relativeActivity(nextAction,{future:true}))}</dd></div>`
          :`<div><dt>Subscription</dt><dd>${escapeHtml(plainLabel(item.subscription_status||'Not recorded'))}</dd></div>`}
        ${canOpenDetail
          ?`<div><dt>Stage age</dt><dd>${stageDays} day${stageDays===1?'':'s'}</dd></div>`
          :`<div><dt>Last activity</dt><dd>${escapeHtml(relativeActivity(item.last_activity_at))}</dd></div>`}
      </dl>
      <div class="platform-card-badges">
        ${CUI.status(stageLabel,'off')}
        ${item.attention_due===true?CUI.status('Due now','no'):''}
        ${attentionSeverity==='critical'?CUI.status('Critical','no'):''}
        ${attentionSeverity==='warning'?CUI.status('Warning','new'):''}
        ${attentionSeverity==='info'?CUI.status('Monitor','off'):''}
        ${stale?CUI.status('Stale','off'):''}${overdue?CUI.status('Overdue','no'):''}
        ${prospectAttentionMatches(item,'clean')?CUI.status('Clean','ok'):''}
        ${completeness?CUI.status(`${Math.max(0,Math.min(100,completeness))}% complete`,completeness>=80?'ok':'new'):''}
        ${progress!==null?CUI.status(`${Math.max(0,Math.min(100,progress))}% onboarded`,progress===100?'ok':'new'):''}
        ${onboarding?CUI.status(plainLabel(onboarding),onboardingTone(onboarding)):''}
        ${summary.mandatoryTotal?CUI.status(`${summary.mandatoryFulfilled}/${summary.mandatoryTotal} required`,'off'):''}
        ${Number(summary.blockedItems?.length||0)>0?CUI.status(`${summary.blockedItems.length} blocked`,'no'):''}
        ${warnings.slice(0,3).map(flag=>CUI.status(plainLabel(flag),'no')).join('')}
        ${stage==='unmapped'?CUI.status('Unmapped','no'):''}
      </div>
      ${tags.length?`<div class="platform-card-tags" aria-label="Tags">${tags.slice(0,4).map(tag=>`<span>${escapeHtml(tag)}</span>`).join('')}</div>`:''}
      ${contactActions}
      ${managed||!canWrite?`<div class="platform-card-actions platform-card-managed" data-card-actions>${canOpenDetail
        ?'<span class="muted small">Evidence-managed lifecycle</span>'
        :'<a class="btn ghost sm" href="#/platform/firms">Open firm directory</a>'}</div>`:`<div class="platform-card-actions" data-card-actions>
        <label class="sr-only" for="move-${escapeHtml(id)}">Move ${escapeHtml(prospectCompany(item))} to stage</label>
        <select id="move-${escapeHtml(id)}" data-move-select>
          ${prospectStages.map(option=>`<option value="${option.key}"${option.key===stage?' selected':''}${['account_created','onboarding','activated'].includes(option.key)?' disabled':''}>${escapeHtml(option.label)}</option>`).join('')}
        </select>
        <button type="button" class="btn ghost sm" data-move aria-label="Move prospect">${CUI.icon('forward',{size:16})}</button>
      </div>`}
    </article>`;
  }
  function flattenBoard(board,listPayload) {
    const listed=asArray(listPayload,['items','prospects']);
    if(listed.length)return listed;
    return asArray(board?.columns).flatMap(column=>asArray(column,['items','prospects','cards']));
  }
  function sortProspects(items,sort) {
    const rows=[...items];
    if(sort==='overdue')return rows.sort((a,b)=>Number(b.overdue_task_count||b.overdue||0)-Number(a.overdue_task_count||a.overdue||0));
    if(sort==='stale')return rows.sort((a,b)=>Number(b.is_stale||b.stale||0)-Number(a.is_stale||a.stale||0));
    if(sort==='complete')return rows.sort((a,b)=>Number(b.completeness_percent||b.completeness||0)-Number(a.completeness_percent||a.completeness||0));
    if(sort==='next_action')return rows.sort((a,b)=>String(a.next_action_at||'9999').localeCompare(String(b.next_action_at||'9999')));
    if(sort==='stage_age')return rows.sort((a,b)=>String(a.stage_entered_at||'9999').localeCompare(String(b.stage_entered_at||'9999')));
    if(sort==='priority')return rows.sort((a,b)=>(priorityRank[b.priority]||0)-(priorityRank[a.priority]||0));
    if(sort==='oldest')return rows.sort((a,b)=>String(a.created_at||a.updated_at||'').localeCompare(String(b.created_at||b.updated_at||'')));
    return rows.sort((a,b)=>String(b.created_at||b.updated_at||b.last_activity_at||'').localeCompare(String(a.created_at||a.updated_at||a.last_activity_at||'')));
  }
  function optionRows(items,valueGetter,labelGetter=value=>value) {
    const values=new Map();
    items.forEach(item=>{
      const value=valueGetter(item);
      if(value&&!values.has(String(value)))values.set(String(value),String(labelGetter(value,item)||value));
    });
    return [...values].sort((a,b)=>a[1].localeCompare(b[1])).map(([value,label])=>({value,label}));
  }
  function nextActionBucket(item) {
    const value=prospectValue(item,'next_action_at','next_activity_at');
    if(!value)return'missing';
    const due=new Date(value),now=new Date();
    if(!Number.isFinite(due.getTime()))return'missing';
    const today=new Date(now.getFullYear(),now.getMonth(),now.getDate());
    const tomorrow=new Date(today);tomorrow.setDate(tomorrow.getDate()+1);
    const nextWeek=new Date(today);nextWeek.setDate(nextWeek.getDate()+8);
    if(due<today)return'overdue';
    if(due<tomorrow)return'today';
    if(due<nextWeek)return'next_7_days';
    return'later';
  }
  function onboardingHealth(item) {
    const summary=asObject(item.onboarding_summary),status=item.onboarding_status||summary.status;
    if(status==='blocked'||summary.blocked===true||Number(summary.blockedItems?.length||0)>0)return'blocked';
    if(status==='ready')return'ready';
    if(item.overdue===true||item.stale===true||Number(item.overdue_task_count||0)>0)return'at_risk';
    if(['account_created','onboarding','activated'].includes(prospectStage(item)))return'on_track';
    return'not_started';
  }
  function prospectIsStale(item) {
    if(item.stale===true||item.is_stale===true)return true;
    if(Object.prototype.hasOwnProperty.call(item,'attention_reason'))
      return String(item.attention_reason||'').includes('stale');
    return Number(item.days_unattended||0)>=7;
  }
  function prospectAttentionMatches(item,filter) {
    if(!filter)return true;
    const severity=String(item.attention_severity||'none').toLowerCase();
    if(filter==='due')return item.attention_due===true;
    if(['critical','warning','info'].includes(filter))return severity===filter;
    if(filter==='stale')return prospectIsStale(item);
    if(filter==='clean')return item.attention_due!==true
      &&severity==='none'
      &&!prospectIsStale(item)
      &&onboardingHealth(item)!=='blocked';
    return false;
  }
  function attentionFilterLabel(value) {
    return{
      due:'Due now',critical:'Critical',warning:'Warning',
      info:'Monitor',stale:'Stale',clean:'Clean'
    }[value]||plainLabel(value);
  }
  function prospectMatchesFilters(item,filters) {
    const search=String(filters.search||'').toLowerCase();
    const searchable=[
      prospectCompany(item),prospectContact(item),
      prospectValue(item,'registration_number','company.registration_number'),
      prospectValue(item,'sector_key','industry','company.industry'),
      prospectValue(item,'boss_name','primary_contact.email','contact_email','boss_email'),
      prospectValue(item,'boss_phone','primary_contact.phone','contact_phone'),
      prospectValue(item,'notes','qualification.notes')
    ].join(' ').toLowerCase();
    const consultant=prospectValue(item,'assigned_consultant_id','consultant_id','assigned_consultant','consultant.id');
    const source=prospectSource(item),region=prospectValue(item,'region','company.region');
    const segment=prospectValue(item,'segment','company.segment','industry','company.industry');
    return(!search||searchable.includes(search))
      &&(!filters.consultant||String(consultant)===filters.consultant)
      &&(!filters.lane||operationalLaneFor(item)===filters.lane)
      &&prospectAttentionMatches(item,filters.attention)
      &&(!filters.stage||prospectStage(item)===filters.stage)
      &&(!filters.source||source===filters.source)
      &&(!filters.region||String(region)===filters.region)
      &&(!filters.segment||String(segment)===filters.segment)
      &&(!filters.priority||String(item.priority||'normal')===filters.priority)
      &&(!filters.qualification||prospectFit(item)===filters.qualification)
      &&(!filters.nextAction||nextActionBucket(item)===filters.nextAction)
      &&(!filters.health||onboardingHealth(item)===filters.health);
  }
  function onboardingFilterSummary(filters,CUI) {
    const labels={
      lane:'Operational status',attention:'Attention',consultant:'Owner',stage:'Stage',source:'Source',region:'Region',segment:'Segment',
      priority:'Priority',qualification:'Qualification',nextAction:'Next action',health:'Health'
    };
    const active=Object.entries(labels).filter(([key])=>filters[key]);
    if(!active.length)return'';
    return `<div class="platform-active-filters" aria-label="Active filters">${CUI.icon('search',{size:16})}<span>Active:</span>${active.map(([key,label])=>`<span class="chip">${escapeHtml(label)} · ${escapeHtml(key==='attention'?attentionFilterLabel(filters[key]):plainLabel(filters[key]))}</span>`).join('')}</div>`;
  }
  function onboardingHtml({board,items,CUI,filters,attentionSummary={},canWrite=true}) {
    const filtered=sortProspects(items.filter(item=>prospectMatchesFilters(item,filters)),filters.sort);
    const byLane=Object.fromEntries(operationalLanes.map(lane=>[
      lane.key,filtered.filter(item=>operationalLaneFor(item)===lane.key)
    ]));
    const owners=optionRows(items,item=>prospectValue(item,'assigned_consultant_id','consultant_id'),
      (_value,item)=>item.consultant_name||item.owner_name||'Assigned owner');
    const sources=optionRows(items,prospectSource),regions=optionRows(items,item=>prospectValue(item,'region','company.region'));
    const segments=optionRows(items,item=>prospectValue(item,'segment','company.segment','industry','company.industry'));
    const qualifications=optionRows(items,prospectFit,value=>plainLabel(value));
    const attention=asObject(attentionSummary);
    const attentionCounts={
      due:Number(attention.due??items.filter(item=>prospectAttentionMatches(item,'due')).length),
      critical:Number(attention.critical??items.filter(item=>prospectAttentionMatches(item,'critical')).length),
      warning:Number(attention.warning??items.filter(item=>prospectAttentionMatches(item,'warning')).length),
      info:Number(attention.info??items.filter(item=>prospectAttentionMatches(item,'info')).length),
      stale:items.filter(item=>prospectAttentionMatches(item,'stale')).length,
      clean:items.filter(item=>prospectAttentionMatches(item,'clean')).length
    };
    return `${CUI.pageHeader({
      title:'Onboarding',
      subtitle:'Move from first contact to activation with evidence-backed onboarding gates and an auditable launch decision.',
      iconName:'setup',
      actions:canWrite?`<button type="button" class="btn ghost" id="platformImportProspects">${CUI.icon('import',{size:17})}<span>Import</span></button><button type="button" class="btn" id="platformNewProspect">${CUI.icon('add',{size:17})}<span>New prospect</span></button>`:''
    })}
      <section class="platform-attention-summary" aria-label="Onboarding attention queue">
        ${[
          ['due','Due now','no'],['critical','Critical','no'],['warning','Warning','new'],
          ['info','Monitor','off'],['stale','Stale','off'],['clean','Clean','ok']
        ].map(([key,label,tone])=>`<button type="button" class="platform-attention-card ${tone}" data-attention-quick="${key}" aria-label="Show ${escapeHtml(label.toLowerCase())} firms">
          <span>${escapeHtml(label)}</span><b>${escapeHtml(attentionCounts[key])}</b>
        </button>`).join('')}
      </section>
      <form class="card platform-filter-panel" id="platformBoardFilters">
        <div class="platform-filter-primary">
          ${CUI.field({id:'platformProspectSearch',label:'Search every firm field',type:'search',value:filters.search,placeholder:'Company, UEN, contact, phone, email or notes'})}
          ${CUI.field({id:'platformLaneFilter',label:'Operational status',control:'select',options:[{value:'',label:'All statuses'},...operationalLanes.map(lane=>({value:lane.key,label:lane.label}))].map(option=>({...option,selected:option.value===filters.lane}))})}
          ${CUI.field({id:'platformAttentionFilter',label:'Attention',control:'select',options:[
            ['','All firms'],['due','Due now'],['critical','Critical'],['warning','Warning'],
            ['info','Monitor'],['stale','Stale'],['clean','Clean']
          ].map(([value,label])=>({value,label,selected:value===filters.attention}))})}
          ${CUI.field({id:'platformProspectSort',label:'Sort',control:'select',options:[
            ['next_action','Next action'],['stage_age','Stage age'],['priority','Priority'],
            ['newest','Newest'],['oldest','Oldest'],['overdue','Overdue first'],['stale','Stale first'],['complete','Completeness']
          ].map(([value,label])=>({value,label,selected:value===filters.sort}))})}
          <div class="platform-filter-submit"><button class="btn" type="submit">${CUI.icon('search',{size:17})}<span>Apply filters</span></button><button class="btn ghost" type="button" id="platformBoardClear">Clear</button></div>
        </div>
        <details class="platform-filter-more"${Object.values(filters).filter(Boolean).length>2?' open':''}>
          <summary>More filters</summary>
          <div class="platform-filter-grid">
            ${CUI.field({id:'platformConsultantFilter',label:'Owner',control:'select',options:[{value:'',label:'All owners'},...owners].map(option=>({...option,selected:option.value===filters.consultant}))})}
            ${CUI.field({id:'platformStageFilter',label:'Stage',control:'select',options:[{value:'',label:'All stages'},...prospectStages,{value:'unmapped',label:'Unmapped'}].map(option=>({value:option.value||option.key,label:option.label,selected:(option.value||option.key)===filters.stage}))})}
            ${CUI.field({id:'platformSourceFilter',label:'Source',control:'select',options:[{value:'',label:'All sources'},...sources].map(option=>({...option,selected:option.value===filters.source}))})}
            ${CUI.field({id:'platformRegionFilter',label:'Region',control:'select',options:[{value:'',label:'All regions'},...regions].map(option=>({...option,selected:option.value===filters.region}))})}
            ${CUI.field({id:'platformSegmentFilter',label:'Segment',control:'select',options:[{value:'',label:'All segments'},...segments].map(option=>({...option,selected:option.value===filters.segment}))})}
            ${CUI.field({id:'platformPriorityFilter',label:'Priority',control:'select',options:[['','All priorities'],['urgent','Urgent'],['high','High'],['normal','Normal'],['low','Low']].map(([value,label])=>({value,label,selected:value===filters.priority}))})}
            ${CUI.field({id:'platformQualificationFilter',label:'Qualification',control:'select',options:[{value:'',label:'All qualification states'},...qualifications].map(option=>({...option,selected:option.value===filters.qualification}))})}
            ${CUI.field({id:'platformNextActionFilter',label:'Next action',control:'select',options:[['','Any date'],['overdue','Overdue'],['today','Today'],['next_7_days','Next 7 days'],['later','Later'],['missing','Missing']].map(([value,label])=>({value,label,selected:value===filters.nextAction}))})}
            ${CUI.field({id:'platformHealthFilter',label:'Onboarding health',control:'select',options:[['','Any health'],['blocked','Blocked'],['at_risk','At risk'],['ready','Ready'],['on_track','On track'],['not_started','Not started']].map(([value,label])=>({value,label,selected:value===filters.health}))})}
          </div>
        </details>
        ${onboardingFilterSummary(filters,CUI)}
      </form>
      <div class="platform-route-note platform-status-note">${CUI.icon('info',{size:19})}<div><b>Five clear operating lanes</b><p class="small">The detailed CRM stages remain intact for audit and automation. These five lanes make the day-to-day workload readable without horizontal scrolling. Open a card or use its stage menu for an exact move.</p></div></div>
      <div class="platform-kanban" aria-label="SME onboarding Kanban">${operationalLanes.map(lane=>`<section class="platform-kanban-column" aria-labelledby="lane-${lane.key}">
        <header class="platform-kanban-head"><div><h2 id="lane-${lane.key}">${escapeHtml(lane.label)}</h2><p>${escapeHtml(lane.description)}</p></div><span class="platform-count">${byLane[lane.key].length}</span></header>
        <div class="platform-card-list">${byLane[lane.key].map(item=>prospectCardHtml(item,CUI,{canWrite})).join('')||`<p class="muted small platform-lane-empty">No firms</p>`}</div>
      </section>`).join('')}</div>
      <div class="platform-prospect-list" aria-label="SME onboarding list">${filtered.map(item=>prospectCardHtml(item,CUI,{mobile:true,canWrite})).join('')||CUI.emptyState({iconName:'setup',title:'No matching prospects',body:'Change the search or consultant filter.'})}</div>`;
  }

  function defaultOnboardingFilters(){
    return{search:'',lane:'',attention:'',consultant:'',stage:'',source:'',region:'',segment:'',priority:'',
      qualification:'',nextAction:'',health:'',sort:'next_action'};
  }
  async function renderOnboarding(context,filters=defaultOnboardingFilters()) {
    const {main,CUI,sb,generation,isCurrent}=context;
    main.innerHTML=loading(CUI,'Onboarding','Loading the SME pipeline…','setup');
    try{
      const [directory,board,list]=await Promise.all([
        fetchFirmDirectoryV88(sb,filters,{required:true}),
        rpc(sb,'platform_get_sme_board_v76',{p_consultant:filters.consultant||null}),
        rpc(sb,'platform_list_prospects_v76',{p_stage:null,p_consultant:filters.consultant||null,p_search:filters.search||null,p_limit:250,p_before:null})
      ]);
      if(generation!==renderGeneration||!main.isConnected||(isCurrent&&!isCurrent()))return;
      const items=mergeFirmOnboardingItems(directory.items,flattenBoard(board,list));
      if(generation!==renderGeneration||!main.isConnected||(isCurrent&&!isCurrent()))return;
      main.innerHTML=onboardingHtml({board,items,CUI,filters,attentionSummary:directory.attention_summary,canWrite:context.canWrite});
      wireOnboarding({...context,board,items,filters});
      CUI.focusRoute(main);
    }catch(error){showError(main,error,CUI,'Onboarding')}
  }
  function wireOnboarding(context) {
    const {main,CUI,items,filters}=context;
    main.querySelector('#platformBoardFilters').onsubmit=event=>{
      event.preventDefault();
      renderOnboarding(context,{
        search:main.querySelector('#platformProspectSearch').value.trim(),
        lane:main.querySelector('#platformLaneFilter').value,
        attention:main.querySelector('#platformAttentionFilter').value,
        consultant:main.querySelector('#platformConsultantFilter').value,
        stage:main.querySelector('#platformStageFilter').value,
        source:main.querySelector('#platformSourceFilter').value,
        region:main.querySelector('#platformRegionFilter').value,
        segment:main.querySelector('#platformSegmentFilter').value,
        priority:main.querySelector('#platformPriorityFilter').value,
        qualification:main.querySelector('#platformQualificationFilter').value,
        nextAction:main.querySelector('#platformNextActionFilter').value,
        health:main.querySelector('#platformHealthFilter').value,
        sort:main.querySelector('#platformProspectSort').value
      });
    };
    main.querySelector('#platformBoardClear').onclick=()=>renderOnboarding(context,defaultOnboardingFilters());
    main.querySelectorAll('[data-attention-quick]').forEach(button=>button.onclick=()=>renderOnboarding(context,{
      ...filters,attention:button.dataset.attentionQuick
    }));
    const newProspect=main.querySelector('#platformNewProspect');
    if(newProspect)newProspect.onclick=()=>newProspectModal(context);
    const importProspects=main.querySelector('#platformImportProspects');
    if(importProspects)importProspects.onclick=()=>prospectImportModal(context);
    main.querySelectorAll('[data-prospect]').forEach(card=>{
      const item=items.find(row=>String(row.id||row.prospect_id)===card.dataset.prospect);
      const open=()=>{
        if(item?._has_prospect_detail===false)globalObject.location.hash='#/platform/firms';
        else openProspectDetail(item,context);
      };
      card.onclick=event=>{if(event.target.closest('[data-card-actions]'))return;open()};
      card.onkeydown=event=>{if((event.key==='Enter'||event.key===' ')&&!event.target.closest('[data-card-actions]')){event.preventDefault();open()}};
      const moveButton=card.querySelector('[data-move]');
      if(moveButton)moveButton.onclick=event=>{
        event.stopPropagation();requestStageMove(item,card.querySelector('[data-move-select]').value,context);
      };
    });
  }
  function newProspectModal(context) {
    const {CUI,sb}=context;
    modal({title:'New prospect',submitLabel:'Create prospect',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'newCompanyName',label:'Company name',required:true,attributes:'name="company_name"'})}
      ${CUI.field({id:'newUen',label:'UEN',attributes:'name="uen"'})}
      ${CUI.field({id:'newContactName',label:'Primary contact',required:true,attributes:'name="contact_name"'})}
      ${CUI.field({id:'newContactEmail',label:'Email',type:'email',attributes:'name="contact_email"'})}
      ${CUI.field({id:'newContactPhone',label:'Phone',attributes:'name="contact_phone"'})}
      ${CUI.field({id:'newConsultant',label:'Consultant ID',attributes:'name="consultant"'})}
      ${CUI.field({id:'newStage',label:'Starting stage',control:'select',options:prospectStages.filter(stage=>!['account_created','onboarding','activated'].includes(stage.key)).map(stage=>({value:stage.key,label:stage.label,selected:stage.key==='new_lead'})),attributes:'name="stage"'})}
      ${CUI.field({id:'newTags',label:'Tags',placeholder:'Comma separated',attributes:'name="tags"'})}
    </div>`,onSubmit:async(form,controls)=>{
      if(!form.get('contact_email')&&!form.get('contact_phone'))throw new Error('Add a contact email or phone number.');
      const data=await rpc(sb,'platform_create_prospect_v76',{
        p_company:{legal_name:form.get('company_name'),registration_number:form.get('uen')||null},
        p_primary_contact:{full_name:form.get('contact_name'),email:form.get('contact_email')||null,phone:form.get('contact_phone')||null},
        p_stage_key:form.get('stage'),p_consultant:form.get('consultant')||null,p_source:{source_system:'platform_console',source_type:'manual'},
        p_tags:String(form.get('tags')||'').split(',').map(value=>value.trim()).filter(Boolean),
        p_idempotency_key:idempotencyKey()
      });
      controls.close();await renderOnboarding(context);
      CUI.announce(`Prospect ${data?.prospect?.company_name||form.get('company_name')} created.`);
    }});
  }
  function prospectImportModal(context) {
    const {CUI,sb}=context;
    let parsed={headers:[],rows:[]},mapping={},batch=null,serverRows=[],analysis=null;
    const overlay=modal({title:'Import prospects',submitLabel:'Analyse import',CUI,body:`
      <div class="platform-import-step" aria-current="step"><span>1</span><div><b>Add source data</b><p class="muted small">CSV, TSV and Excel are accepted. Nothing is inserted until review is complete.</p></div></div>
      <label for="platformImportSource">Source name</label><input id="platformImportSource" name="source" value="Platform import" required>
      <label for="platformImportPaste">Paste CSV or tab-separated rows</label>
      <textarea id="platformImportPaste" name="paste" rows="7" placeholder="Company Name,Contact Person,Email Address"></textarea>
      <label for="platformImportFile">Or choose CSV / TSV / XLSX</label><input id="platformImportFile" type="file" accept=".csv,.tsv,.xlsx,.xls,text/csv,text/tab-separated-values">
      <button type="button" class="btn ghost sm" data-import-columns style="margin-top:10px">${CUI.icon('search',{size:16})}<span>Preview and map columns</span></button>
      <div class="platform-import-preview" data-preview aria-live="polite"></div>`,onSubmit:async(form,controls)=>{
        if(!CRM)throw new Error('The enterprise import mapper is unavailable.');
        if(!parsed.rows.length)parsePastedImport(controls.overlay);
        if(!parsed.rows.length)throw new Error('Add at least one prospect row.');
        collectImportMapping(controls.overlay);
        const conflicts=CRM.mappingConflicts(mapping);
        if(conflicts.length)throw new Error(`Map each single-value field once. Conflict: ${conflicts.map(item=>plainLabel(item.destination)).join(', ')}.`);
        if(!Object.values(mapping).includes('company_name'))throw new Error('Map one source column to Company name.');
        const mapped=CRM.analyseImportRows(CRM.mapImportRows(parsed.rows,mapping));
        const localSummary=CRM.importSummary(mapped);
        if(localSummary.invalid===localSummary.total)throw new Error('Every row has a validation error. Correct the mapping or source data.');
        const staged=await rpc(sb,'platform_stage_prospect_import_v76',{
          p_source_system:'platform_console',p_source_name:form.get('source'),
          p_rows:parsed.rows.map(row=>row.values),p_idempotency_key:idempotencyKey()
        });
        batch=staged.batch_id||staged.batch?.id||staged.batch;
        const canonicalMapping=Object.fromEntries(Object.entries(mapping)
          .filter(([,destination])=>Boolean(destination))
          .map(([header,destination])=>[
            destination.startsWith('custom:')?`custom__${destination.slice('custom:'.length)}`:destination,
            header
          ]));
        analysis=asObject(await rpc(sb,'platform_analyse_prospect_import_v86',{
          p_batch:batch,p_column_mapping:canonicalMapping
        }));
        const errorPayload=asObject(await rpc(sb,'platform_get_import_errors_v86',{
          p_batch:batch,p_limit:500,p_after_row:null
        }));
        serverRows=asArray(errorPayload,['items']);
        renderImportDecisionStep({controls,staged,localSummary});
      }});
    function parsePastedImport(host){
      parsed=CRM.parseDelimited(host.querySelector('#platformImportPaste').value);
      mapping=CRM.suggestMapping(parsed.headers);
      renderImportMapping(host);
    }
    function collectImportMapping(host){
      host.querySelectorAll('[data-import-map]').forEach(select=>{
        mapping[select.dataset.importMap]=select.value;
      });
    }
    function renderImportMapping(host){
      const preview=host.querySelector('[data-preview]');
      if(!parsed.rows.length){
        preview.innerHTML='<div class="err">Include a header row and at least one data row.</div>';return;
      }
      const mapped=CRM.analyseImportRows(CRM.mapImportRows(parsed.rows,mapping)),summary=CRM.importSummary(mapped);
      preview.innerHTML=`<section class="platform-import-mapping" aria-labelledby="importMapTitle">
        <div class="platform-import-step"><span>2</span><div><b id="importMapTitle">Map every source column</b><p class="muted small">Unknown columns stay preserved with their source labels. Single-value fields may only be mapped once.</p></div></div>
        <div class="platform-import-map-grid">${parsed.headers.map(header=>`<div><label for="import-map-${escapeHtml(CRM.normaliseHeader(header).replace(/\s/g,'-'))}">${escapeHtml(header)}</label><select id="import-map-${escapeHtml(CRM.normaliseHeader(header).replace(/\s/g,'-'))}" data-import-map="${escapeHtml(header)}">
          ${[...CRM.importFields,{key:CRM.customFieldKey(header),label:`Custom source field · ${header}`}].map(field=>`<option value="${escapeHtml(field.key)}"${mapping[header]===field.key?' selected':''}>${escapeHtml(field.label)}</option>`).join('')}
        </select></div>`).join('')}</div>
        <div class="platform-import-summary" role="status"><b>${summary.total} rows</b><span>${summary.ready} ready</span><span>${summary.review} review</span><span>${summary.invalid} invalid</span></div>
        <div class="cui-table-wrap" role="region" aria-label="Import sample" tabindex="0"><table class="cui-table"><caption>First five source rows</caption><thead><tr>${parsed.headers.map(header=>`<th scope="col">${escapeHtml(header)}</th>`).join('')}</tr></thead><tbody>${parsed.rows.slice(0,5).map(row=>`<tr>${parsed.headers.map(header=>`<td data-label="${escapeHtml(header)}">${escapeHtml(row.values[header])}</td>`).join('')}</tr>`).join('')}</tbody></table></div>
      </section>`;
      preview.querySelectorAll('[data-import-map]').forEach(select=>select.onchange=()=>{
        collectImportMapping(host);renderImportMapping(host);
      });
    }
    function renderImportDecisionStep({controls,staged,localSummary}){
      const preview=controls.overlay.querySelector('[data-preview]');
      const counts={
        valid:Number(analysis.valid_rows??staged.valid_rows??0),
        unmapped:Number(analysis.unmapped_rows??staged.unmapped_rows??0),
        conflicts:Number(analysis.conflict_rows??staged.conflict_rows??0),
        invalid:Number(analysis.invalid_rows??staged.invalid_rows??0)
      };
      preview.innerHTML=`<section class="platform-import-results" aria-labelledby="importDecisionTitle">
        <div class="platform-import-step"><span>3</span><div><b id="importDecisionTitle">Review analysis and decisions</b><p class="muted small">The server checked existing prospects and preserved the original source row. Conflicts must stay in review, be skipped, or be deliberately merged.</p></div></div>
        <div class="platform-import-summary"><b>${localSummary.total} rows</b><span>${counts.valid} valid</span><span>${counts.unmapped} unmapped</span><span>${counts.conflicts} conflicts</span><span>${counts.invalid} invalid</span></div>
        ${serverRows.length?`<div class="platform-import-review-list">${serverRows.map(row=>importReviewRowHtml(row)).join('')}</div>`:'<p class="muted small">No conflict or validation rows require individual attention.</p>'}
        <div class="platform-actions"><button type="button" class="btn ghost sm" data-import-errors>${CUI.icon('export',{size:16})}<span>Download error CSV</span></button></div>
        <label class="row platform-confirm-row"><input type="checkbox" data-import-confirm><span>I reviewed the mapping, validation results, and every conflict decision.</span></label>
      </section>`;
      preview.querySelectorAll('[data-import-decision]').forEach(select=>select.onchange=()=>saveImportDecision(select,controls));
      preview.querySelector('[data-import-errors]').onclick=()=>downloadImportErrors(serverRows,batch,context);
      controls.submit.textContent='Commit reviewed import';controls.submit.disabled=false;
      controls.overlay.querySelector('[data-form]').onsubmit=async event=>{
        event.preventDefault();
        if(!controls.overlay.querySelector('[data-import-confirm]')?.checked){
          controls.errorHost.innerHTML='<div class="err">Review and confirm the analysed import first.</div>';return;
        }
        if([...controls.overlay.querySelectorAll('[data-import-decision]')].some(select=>select.value==='review')){
          controls.errorHost.innerHTML='<div class="err">Resolve every row still marked Review before committing.</div>';return;
        }
        controls.submit.disabled=true;controls.errorHost.innerHTML='';
        try{
          const committed=await commitProspectImport(sb,batch);
          renderCommittedImport(controls,committed,batch,context);
          await renderOnboarding(context);
        }catch(error){controls.errorHost.innerHTML=`<div class="err">${escapeHtml(error.message)}</div>`;controls.submit.disabled=false}
      };
    }
    overlay.querySelector('[data-import-columns]').onclick=()=>parsePastedImport(overlay);
    const file=overlay.querySelector('#platformImportFile');
    file.onchange=async()=>{
      const selected=file.files?.[0];if(!selected)return;
      if(/\.xlsx?$/i.test(selected.name)&&globalObject.XLSX){
        const workbook=globalObject.XLSX.read(await selected.arrayBuffer(),{type:'array'});
        const matrix=globalObject.XLSX.utils.sheet_to_json(workbook.Sheets[workbook.SheetNames[0]],{header:1,raw:false});
        parsed=matrixImportSource(matrix);
      }else parsed=CRM.parseDelimited(await selected.text());
      mapping=CRM.suggestMapping(parsed.headers);renderImportMapping(overlay);
    };
  }
  function importReviewRowHtml(row) {
    const id=row.import_row_id||row.id||'',candidates=asArray(row.candidates);
    const suggested=row.row_status==='invalid'?'skip':row.row_status==='conflict'?'review':'insert';
    return `<article class="platform-import-review-row">
      <div><b>Source row ${escapeHtml(row.row_number)}</b><p class="muted small">${escapeHtml(plainLabel(row.row_status))}${asArray(row.errors).length?` · ${escapeHtml(asArray(row.errors).map(plainLabel).join(', '))}`:''}</p>
        ${candidates.length?`<p class="small">${candidates.map(candidate=>`${plainLabel(candidate.match_basis)} ${candidate.score}% · ${candidate.candidate_prospect_id}`).map(escapeHtml).join('<br>')}</p>`:''}</div>
      <div><label class="sr-only" for="import-decision-${escapeHtml(row.row_number)}">Decision for source row ${escapeHtml(row.row_number)}</label><select id="import-decision-${escapeHtml(row.row_number)}" data-import-decision data-import-row="${escapeHtml(id)}" data-candidate="${escapeHtml(candidates[0]?.candidate_prospect_id||'')}"${id?'':' disabled title="A backend update is required for per-row decisions."'}>
        ${[['review','Review'],['insert','Insert new'],['skip','Skip'],...(candidates.length?[['merge','Merge source lineage']]:[])].map(([value,label])=>`<option value="${value}"${value===suggested?' selected':''}>${label}</option>`).join('')}
      </select></div>
    </article>`;
  }
  async function saveImportDecision(select,controls) {
    const row=select.dataset.importRow,decision=select.value;
    if(!row)return;
    select.disabled=true;controls.errorHost.innerHTML='';
    try{
      await rpc(activeContext.sb,'platform_decide_import_row_v86',{
        p_import_row:row,p_decision:decision,
        p_candidate_prospect:decision==='merge'?(select.dataset.candidate||null):null,
        p_reason:`Platform import review: ${decision}`
      });
    }catch(error){
      select.value='review';controls.errorHost.innerHTML=`<div class="err">${escapeHtml(error.message)}</div>`;
    }finally{select.disabled=false}
  }
  function downloadImportErrors(rows,batch,context) {
    downloadCsv(`${context.brand?.downloadPrefix||'nestly'}-import-${batch}-errors.csv`,[
      ['row_number','status','errors','candidate_matches','raw_payload'],
      ...rows.map(row=>[
        row.row_number,row.row_status,asArray(row.errors).join('|'),
        asArray(row.candidates).map(candidate=>`${candidate.match_basis}:${candidate.candidate_prospect_id}:${candidate.score}`).join('|'),
        JSON.stringify(row.raw_payload||{})
      ])
    ]);
  }
  async function commitProspectImport(sb,batch) {
    try{return await rpc(sb,'platform_commit_prospect_import_v86',{p_batch:batch})}
    catch(error){
      if(!error.platformUpdateRequired)throw error;
      return rpc(sb,'platform_commit_prospect_import_v76',{p_batch:batch,p_idempotency_key:idempotencyKey()});
    }
  }
  function renderCommittedImport(controls,committed,batch,context) {
    const inserted=Number(committed.inserted_rows??committed.imported_rows??committed.imported_count??committed.imported??0);
    const merged=Number(committed.merged_rows??0),skipped=Number(committed.skipped_rows??0);
    controls.overlay.querySelector('[data-preview]').innerHTML=`<section class="platform-import-results">
      <div class="platform-import-step"><span>${context.CUI.icon('check',{size:17})}</span><div><b>Import completed</b><p class="muted small">${inserted} inserted · ${merged} merged · ${skipped} skipped. Source lineage and batch provenance were retained.</p></div></div>
      <div class="platform-route-note"><div><b>Guarded rollback</b><p class="small">Unused, unedited inserts are moved to Lost with immutable import provenance retained. Reviewed merge links are detached. The backend refuses reversal after later use or edits.</p><label for="platformImportRollbackReason">Rollback reason</label><input id="platformImportRollbackReason" data-import-rollback-reason><button type="button" class="btn danger sm" data-import-rollback>Rollback this batch</button></div></div>
    </section>`;
    controls.submit.hidden=true;
    controls.overlay.querySelector('[data-import-rollback]').onclick=async event=>{
      const reason=controls.overlay.querySelector('[data-import-rollback-reason]').value.trim();
      if(reason.length<2){controls.errorHost.innerHTML='<div class="err">Enter a rollback reason.</div>';return}
      if(!globalObject.confirm('Rollback this import batch? Eligible inserts will be tombstoned as Lost and immutable audit provenance will remain.'))return;
      event.currentTarget.disabled=true;
      try{
        const result=await rpc(activeContext.sb,'platform_reverse_prospect_import_v86',{p_batch:batch,p_reason:reason});
        controls.close();await renderOnboarding(activeContext);
        activeContext.CUI.announce(`Import reversed: ${Number(result.reversed_insert_rows||0)} insert records tombstoned and ${Number(result.unlinked_merge_rows||0)} merge links detached. Audit provenance was preserved.`);
      }catch(error){controls.errorHost.innerHTML=`<div class="err">${escapeHtml(error.message)}</div>`;event.currentTarget.disabled=false}
    };
  }
  function parseTableText(text) {
    if(!CRM)return[];
    return CRM.parseDelimited(text).rows.map(row=>row.values);
  }
  function matrixToObjects(matrix) {
    const headers=(matrix[0]||[]).map(value=>String(value||'').trim());
    return matrix.slice(1).filter(row=>row.some(value=>String(value||'').trim())).map(row=>Object.fromEntries(headers.map((header,index)=>[header,row[index]??null])));
  }
  function matrixImportSource(matrix) {
    const headers=(matrix[0]||[]).map((value,index)=>String(value||'').trim()||`Column ${index+1}`);
    return{delimiter:',',headers,rows:matrix.slice(1).filter(row=>row.some(value=>String(value||'').trim())).map((row,index)=>({
      row_number:index+2,values:Object.fromEntries(headers.map((header,column)=>[header,String(row[column]??'').trim()]))
    }))};
  }
  async function openProspectDetail(item,context) {
    const {CUI,sb}=context,id=item.id||item.prospect_id;
    const overlay=document.createElement('div');overlay.className='platform-drawer';overlay.tabIndex=-1;
    overlay.innerHTML=`<section class="platform-drawer-panel"><div class="platform-drawer-head"><div><h1 id="prospectDetailTitle" style="font-size:1.45rem">${escapeHtml(prospectCompany(item))}</h1><p class="muted small">Loading complete prospect detail…</p></div><button type="button" class="btn ghost sm platform-drawer-close" aria-label="Close detail">${CUI.icon('close',{size:18})}</button></div><div data-detail>${CUI.loadingState({title:'Prospect detail',body:'Loading contacts, activities, tasks and commercial context…',iconName:'customers'})}</div></section>`;
    document.body.appendChild(overlay);
    let deactivate,closed=false,boardDirty=false;
    const close=()=>{
      if(closed)return;
      closed=true;closeOverlay(overlay,deactivate);
      if(boardDirty)renderOnboarding(context);
    };
    overlay.querySelector('.platform-drawer-close').onclick=close;
    deactivate=CUI.activateDialog(overlay,{onClose:close,initialFocus:'.platform-drawer-close'});
    try{
      await refreshProspectDrawer({...context,overlay,close,markBoardDirty:()=>{boardDirty=true}},id);
    }catch(error){
      overlay.querySelector('[data-detail]').innerHTML=error.platformUpdateRequired
        ?systemUpdateRequired(CUI,'Prospect detail')
        :CUI.errorState({title:'Prospect detail unavailable',message:error.message});
    }
  }
  async function loadProspectDetail(sb,id) {
    const legacy=asObject(await rpc(sb,'platform_get_prospect_detail_v76',{p_prospect:id}));
    let extended={},audit={};
    try{
      extended=asObject(await rpc(sb,'platform_get_prospect_detail_v86',{
        p_prospect:id,p_snapshot_at:null,p_limit:100
      }));
      audit=asObject(await rpc(sb,'platform_list_prospect_audit_v86',{
        p_prospect:id,p_snapshot_at:extended.snapshot_at||null,p_limit:100,
        p_after_created_at:null,p_after_id:null
      }));
    }catch(error){
      if(!error.platformUpdateRequired)throw error;
      extended={v86_unavailable:true};audit={items:[]};
    }
    const detail={
      ...legacy,...extended,
      prospect:extended.prospect||legacy.prospect,
      company:extended.company||legacy.company,
      contacts:asArray(extended.contacts).length?extended.contacts:legacy.contacts,
      qualification:extended.qualification||legacy.qualification,
      commercial_terms:extended.commercial_terms||legacy.commercial_terms,
      activities:asArray(extended.activities).length?extended.activities:legacy.activities,
      audit:asArray(audit,['items'])
    };
    const prospect=asObject(detail.prospect);
    if(prospect.converted_business_id){
      try{
        detail.onboarding=asObject(await rpc(sb,'get_business_onboarding_v79',{
          p_business:prospect.converted_business_id
        }));
      }catch(error){
        detail.onboarding_error=error;
      }
    }
    return detail;
  }
  async function refreshProspectDrawer(context,id) {
    const {overlay,CUI,sb}=context;
    const detail=await loadProspectDetail(sb,id);
    if(!overlay.isConnected)return detail;
    const prospect=asObject(detail.prospect);
    overlay.querySelector('#prospectDetailTitle').textContent=prospectCompany({...prospect,...asObject(detail.company)});
    overlay.querySelector('[data-detail]').innerHTML=prospectDetailHtml(
      detail,CUI,context.access?.role==='super_admin'
    );
    wireProspectDetail(detail,context);
    return detail;
  }
  function detailObjectHtml(value,empty='Not recorded') {
    const object=asObject(value),entries=Object.entries(object).filter(([,item])=>item!==null&&item!==''&&item!==undefined);
    if(!entries.length)return`<p class="muted small">${escapeHtml(empty)}</p>`;
    return `<dl class="platform-context-list">${entries.map(([key,item])=>`<div><dt>${escapeHtml(plainLabel(key))}</dt><dd>${escapeHtml(typeof item==='object'?JSON.stringify(item):item)}</dd></div>`).join('')}</dl>`;
  }
  function formatDetailValue(value) {
    if(value===true)return'Yes';
    if(value===false)return'No';
    if(Array.isArray(value))return value.length?value.join(', '):'—';
    if(value&&typeof value==='object')return Object.keys(value).length?JSON.stringify(value):'—';
    return value===null||value===undefined||value===''?'—':String(value);
  }
  function typedDetailHtml(value,fields,empty='Not recorded') {
    const object=asObject(value);
    const rows=fields.map(field=>{
      const [key,label,formatter]=field;
      const raw=object[key],shown=formatter?formatter(raw,object):formatDetailValue(raw);
      return`<div><dt>${escapeHtml(label)}</dt><dd>${escapeHtml(shown)}</dd></div>`;
    });
    return rows.length?`<dl class="platform-context-list platform-typed-list">${rows.join('')}</dl>`:`<p class="muted small">${escapeHtml(empty)}</p>`;
  }
  const contactBase=row=>asObject(row.contact||row);
  const contactExtended=row=>asObject(row.profile);
  const commercialBase=value=>asObject(value?.terms||value);
  const commercialExtended=value=>asObject(value?.detail);
  function sectionHeader(title,action='') {
    return`<div class="platform-list-row"><h2>${escapeHtml(title)}</h2>${action}</div>`;
  }
  function onboardingPanelHtml(payload,error,CUI,isSuperAdmin=false) {
    if(error)return CUI.card({
      title:'Evidence-backed onboarding',
      body:error.platformUpdateRequired
        ?'<p class="muted small">A system update is required before this checklist can be managed.</p>'
        :`<div class="err">${escapeHtml(error.message||'The onboarding checklist could not be loaded.')}</div>`
    });
    const onboarding=asObject(payload),checklist=asObject(onboarding.checklist);
    if(!checklist.id)return CUI.card({
      title:'Evidence-backed onboarding',
      body:'<p class="muted small">No onboarding checklist was returned for this workspace.</p>'
    });
    const facts=onboardingFacts(onboarding),items=asArray(onboarding.items);
    const invitations=asArray(onboarding.owner_invitations),events=asArray(onboarding.events);
    const ownerAccess=items.find(item=>item.item_key==='owner_access');
    const canStart=facts.status==='not_started'&&ownerAccess?.status==='satisfied';
    const activationReady=facts.ready&&!facts.blocked
      &&items.filter(item=>item.mandatory===true).every(item=>['satisfied','waived'].includes(item.status))
      &&items.some(item=>item.item_key==='go_live_approved'&&item.status==='satisfied');
    const blockers=[
      ...(checklist.blocked_at?[{label:'Whole onboarding',reason:checklist.blocked_reason}]:[]),
      ...facts.blockedItems.map(item=>({label:item.label||plainLabel(item.item_key),reason:item.block_reason}))
    ];
    return `<section class="card platform-detail-section" aria-labelledby="onboardingChecklistTitle">
      <div class="platform-drawer-head" style="margin-bottom:10px">
        <div><h2 id="onboardingChecklistTitle">Evidence-backed onboarding</h2><p class="muted small">Checklist version ${escapeHtml(facts.version)} · only recorded evidence changes readiness.</p></div>
        ${CUI.status(plainLabel(facts.status),onboardingTone(facts.status))}
      </div>
      <div class="platform-detail-grid">
        ${detailObjectHtml({
          business:onboarding.business?.name,
          plan:onboarding.subscription?.plan_code,
          billing_cadence:onboarding.subscription?.billing_cadence,
          required_items:`${facts.mandatoryFulfilled} of ${facts.mandatoryTotal}`,
          started_at:dateTime(checklist.started_at),
          activated_at:dateTime(checklist.activated_at)
        })}
        ${blockers.length?`<div><b>Active blockers</b><ul class="platform-error-list">${blockers.map(blocker=>`<li><b>${escapeHtml(blocker.label)}</b>: ${escapeHtml(blocker.reason||'No reason recorded')}</li>`).join('')}</ul></div>`:'<div><b>Active blockers</b><p class="muted small">No active blockers recorded.</p></div>'}
      </div>
      ${facts.activated?'':`<div class="platform-actions" style="margin-top:14px">
        ${facts.status==='not_started'?`<button type="button" class="btn sm" data-onboarding-start${canStart?'':' disabled title="The workspace owner must accept access first."'}>${CUI.icon('forward',{size:16})}<span>Start onboarding</span></button>`:''}
        <button type="button" class="btn ghost sm" data-onboarding-refresh>${CUI.icon('retention',{size:16})}<span>Refresh evidence</span></button>
        <button type="button" class="btn ghost sm" data-onboarding-reissue>${CUI.icon('customers',{size:16})}<span>Reissue owner invite</span></button>
        ${superAdminOnly(isSuperAdmin,checklist.blocked_at
          ?'<button type="button" class="btn ghost sm" data-onboarding-unblock>Unblock onboarding</button>'
          :'<button type="button" class="btn danger sm" data-onboarding-block>Block onboarding</button>')}
        ${superAdminOnly(isSuperAdmin,`<button type="button" class="btn sm" data-onboarding-activate${activationReady?'':' disabled title="Complete every mandatory item and super-admin go-live approval first."'}>${CUI.icon('check',{size:16})}<span>Activate firm</span></button>`)}
      </div>`}
      ${!facts.activated&&!isSuperAdmin?'<p class="muted small" data-super-admin-onboarding-note>Final waivers, blocking decisions, and firm activation are completed by a super admin.</p>':''}
      <h3 style="font-size:14px;margin-top:16px">Checklist</h3>
      <div>${items.map(item=>{
        const canRecord=!facts.activated&&['manual','sa_approval'].includes(item.verification_mode)&&item.status!=='blocked';
        const canWaive=!facts.activated&&item.waivable===true&&item.item_key!=='go_live_approved'&&item.status==='pending';
        return `<article class="platform-action-item">
          <div><b>${escapeHtml(item.label||plainLabel(item.item_key))}</b>
            <p class="muted small">${escapeHtml(plainLabel(item.category))} · ${escapeHtml(plainLabel(item.verification_mode))}${item.mandatory?' · required':' · optional'}</p>
            ${item.block_reason?`<p class="small">Blocked: ${escapeHtml(item.block_reason)}</p>`:''}
            ${item.waiver_reason?`<p class="small">Waived: ${escapeHtml(item.waiver_reason)}</p>`:''}
            ${Object.keys(asObject(item.evidence)).length?`<p class="muted small">Evidence: ${escapeHtml(JSON.stringify(item.evidence))}</p>`:''}
          </div>
          <div><div style="text-align:right">${CUI.status(plainLabel(item.status),item.status==='satisfied'?'ok':item.status==='blocked'?'no':'off')}</div>
            ${facts.activated?'':`<div class="platform-actions" style="justify-content:flex-end;margin-top:6px">
              ${canRecord?`<button type="button" class="btn ghost sm" data-onboarding-evidence="${escapeHtml(item.item_key)}">${item.status==='satisfied'?'Update evidence':'Record evidence'}</button>`:''}
              ${superAdminOnly(isSuperAdmin&&canWaive,`<button type="button" class="btn ghost sm" data-onboarding-waive="${escapeHtml(item.item_key)}">Waive</button>`)}
              ${superAdminOnly(isSuperAdmin,item.status==='blocked'
                ?`<button type="button" class="btn ghost sm" data-onboarding-item-unblock="${escapeHtml(item.item_key)}">Unblock</button>`
                :`<button type="button" class="btn danger sm" data-onboarding-item-block="${escapeHtml(item.item_key)}">Block</button>`)}
            </div>`}
          </div>
        </article>`;
      }).join('')}</div>
      <div class="platform-detail-grid" style="margin-top:14px">
        <div><h3 style="font-size:14px">Owner invitations</h3>${invitations.length?invitations.map(invitation=>`<div class="platform-action-item"><div><b>${escapeHtml(invitation.owner_email)}</b><p class="muted small">Version ${escapeHtml(invitation.version)} · ends in ${escapeHtml(invitation.token_last_four||'—')}</p></div><div>${CUI.status(plainLabel(invitation.status),invitation.status==='accepted'?'ok':invitation.status==='pending'?'new':'off')}<p class="muted small">${escapeHtml(dateTime(invitation.expires_at))}</p></div></div>`).join(''):'<p class="muted small">No owner invitations returned.</p>'}</div>
        <div><h3 style="font-size:14px">Recent evidence events</h3>${events.length?[...events].reverse().slice(0,20).map(event=>`<div class="platform-action-item"><div><b>${escapeHtml(plainLabel(event.event_type))}</b><p class="muted small">${escapeHtml(event.to_status?`To ${plainLabel(event.to_status)}`:'Recorded')}</p></div><span class="muted small">${escapeHtml(dateTime(event.created_at))}</span></div>`).join(''):'<p class="muted small">No onboarding events returned.</p>'}</div>
      </div>
    </section>`;
  }
  function prospectDetailHtml(detail,CUI,isSuperAdmin=false) {
    const prospect=asObject(detail.prospect),company=asObject(detail.company),assignment=asObject(detail.assignment);
    const contacts=asArray(detail.contacts),activities=asArray(detail.activities),tasks=asArray(detail.tasks);
    const stage=prospectStage(prospect),converted=Boolean(prospect.converted_business_id);
    const companyProfile=asObject(detail.company_profile),qualification=asObject(detail.qualification);
    const terms=commercialBase(detail.commercial_terms),commercialDetail=commercialExtended(detail.commercial_terms);
    const conversion=asObject(detail.conversion_configuration),documents=asArray(detail.documents);
    const audit=asArray(detail.audit),quality=asObject(detail.data_quality),stageEvidence=asArray(detail.stage_evidence);
    const termsAccepted=['accepted','signed'].includes(terms.contract_status);
    const primaryRow=contacts.find(row=>contactBase(row).is_primary)||contacts[0]||{},primary=contactBase(primaryRow);
    const whatsapp=contactExtended(primaryRow).whatsapp_e164||contactExtended(primaryRow).whatsapp_original||primary.phone;
    const callPhone=normalizePlatformPhone(primary.phone),whatsappPhone=normalizePlatformPhone(whatsapp);
    return `<nav class="platform-detail-nav" aria-label="Prospect detail sections">
      ${[
        ['detail-overview','Overview'],['detail-company','Company'],['detail-contacts','Contacts'],
        ['detail-qualification','Qualification'],['detail-activities','Activities'],['detail-tasks','Tasks'],
        ['detail-commercial','Commercial'],['detail-documents','Documents'],['detail-conversion','Account'],
        ['detail-onboarding','Onboarding'],['detail-audit','Audit']
      ].map(([id,label])=>`<button type="button" data-detail-section="${id}">${escapeHtml(label)}</button>`).join('')}
    </nav>
    <div class="platform-actions platform-detail-shortcuts">
      ${callPhone?`<a class="btn ghost sm" href="tel:${escapeHtml(callPhone.tel)}">${CUI.icon('till',{size:16})}<span>Call</span></a>`:''}
      ${whatsappPhone?`<a class="btn ghost sm" href="https://wa.me/${escapeHtml(whatsappPhone.wa)}" target="_blank" rel="noopener">${CUI.icon('customers',{size:16})}<span>WhatsApp</span></a>`:''}
      ${primary.email?`<a class="btn ghost sm" href="mailto:${escapeHtml(primary.email)}">${CUI.icon('empty',{size:16})}<span>Email</span></a>`:''}
      <button type="button" class="btn ghost sm" data-add-activity="meeting">${CUI.icon('appointments',{size:16})}<span>Schedule meeting</span></button>
      ${converted?'':`<button type="button" class="btn ghost sm" data-edit-prospect>${CUI.icon('edit',{size:16})}<span>Edit</span></button>
      <button type="button" class="btn ghost sm" data-assign-prospect>${CUI.icon('staff',{size:16})}<span>Assign</span></button>`}
      <button type="button" class="btn sm" data-add-note>${CUI.icon('add',{size:16})}<span>Add note</span></button>
      <button type="button" class="btn ghost sm" data-add-npu>Record NPU</button>
      <button type="button" class="btn ghost sm" data-add-task>${CUI.icon('appointments',{size:16})}<span>Add task</span></button>
      <button type="button" class="btn ghost sm" data-upload-document>${CUI.icon('import',{size:16})}<span>Upload document</span></button>
      ${converted?'<span class="muted small">Account lifecycle is controlled by onboarding evidence.</span>':stage==='client'
        ?`<button type="button" class="btn" data-create-account${termsAccepted?'':' disabled title="Accepted or signed commercial terms are required."'}>${CUI.icon('branch',{size:16})}<span>Create Nestly account</span></button>`
        :'<button type="button" class="btn ghost sm" data-convert>Convert to client</button>'}
      ${converted||stage==='lost'?'':'<button type="button" class="btn danger sm" data-lost>Mark lost</button>'}
    </div>
    <section class="card platform-detail-section" id="detail-overview">
      ${sectionHeader('Overview',`<button type="button" class="btn ghost sm" data-refresh-quality>${CUI.icon('retention',{size:16})}<span>Refresh quality</span></button>`)}
      <div class="platform-detail-grid">
        ${typedDetailHtml({...prospect,...company},[
          ['current_stage_key','Stage',plainLabel],['priority','Priority',plainLabel],
          ['region','Region'],['next_action_at','Next action',dateTime],
          ['stage_entered_at','Stage entered',dateTime],['converted_at','Converted',dateTime]
        ])}
        ${typedDetailHtml({
          assigned_owner:assignment.consultant_name||assignment.display_name||prospect.assigned_consultant_id,
          completeness_score:quality.score,
          quality_evaluated_at:quality.evaluated_at,
          source_count:asArray(detail.sources).length,
          tags:asArray(detail.tags).map(tag=>tag.label||tag.tag_key||tag)
        },[
          ['assigned_owner','Assigned owner'],['completeness_score','Data completeness',value=>value===undefined?'Not evaluated':`${value}%`],
          ['quality_evaluated_at','Quality evaluated',dateTime],['source_count','Source records'],['tags','Tags']
        ])}
      </div>
      ${asArray(quality.rule_results).length?`<div class="platform-quality-rules">${asArray(quality.rule_results).map(rule=>`<span class="${rule.passed?'pass':'fail'}">${CUI.icon(rule.passed?'check':'info',{size:14})}${escapeHtml(rule.label)}</span>`).join('')}</div>`:''}
    </section>
    <section class="card platform-detail-section" id="detail-company">
      ${sectionHeader('Company identity and operating profile',`<div class="platform-actions">${converted?'':`<button type="button" class="btn ghost sm" data-edit-prospect>Edit core identity</button>`}<button type="button" class="btn ghost sm" data-edit-company-profile>Edit operating profile</button></div>`)}
      <div class="platform-detail-grid">
        ${typedDetailHtml(company,[
          ['legal_name','Legal name'],['trading_name','Trading name'],['registration_number','UEN / registration'],
          ['industry','Industry'],['website','Website'],['email','General email'],['phone','General phone']
        ])}
        ${typedDetailHtml(companyProfile,[
          ['entity_type','Entity type',plainLabel],['business_status','Business status',plainLabel],
          ['incorporated_on','Incorporated'],['registered_address','Registered address'],
          ['operating_address','Operating address'],['postal_code','Postal code'],
          ['region_state','Region / state'],['verification_status','Verification',plainLabel]
        ])}
      </div>
      <details class="platform-detail-more"><summary>Business profile and system readiness</summary>${typedDetailHtml(companyProfile,[
        ['main_business_activity','Main business activity'],['sub_industry','Sub-industry'],
        ['business_description','Description'],['employee_range','Employee range'],['expected_seats','Expected seats'],
        ['location_count','Locations'],['customer_type','Customer type',plainLabel],['digital_maturity','Digital maturity',plainLabel],
        ['existing_tools','Existing tools'],['existing_crm','Existing CRM'],['existing_accounting','Existing accounting'],
        ['manual_workflows','Manual workflows'],['required_integrations','Required integrations'],
        ['migration_volume','Migration volume'],['procurement_security_requirements','Procurement / security'],
        ['regulatory_compliance_needs','Regulatory / compliance'],['source_name','Profile source'],
        ['verified_at','Verified at',dateTime],['verification_notes','Verification notes']
      ])}</details>
    </section>
    <section class="card platform-detail-section" id="detail-contacts">
      ${sectionHeader('Contacts and buying committee',`<button type="button" class="btn ghost sm" data-add-contact>${CUI.icon('add',{size:16})}<span>Add contact</span></button>`)}
      ${contacts.length?`<div class="platform-contact-grid">${contacts.map(row=>{
        const contact=contactBase(row),profile=contactExtended(row);
        return`<article class="platform-contact-card"><div class="platform-list-row"><div><b>${escapeHtml(contact.full_name||'Unnamed contact')}</b><p class="muted small">${escapeHtml(contact.title||profile.department_function||'Role not recorded')}</p></div>${contact.is_primary?CUI.status('Primary','ok'):''}</div>
          ${typedDetailHtml({...contact,...profile},[
            ['decision_role','Decision role',plainLabel],['email','Email'],['phone','Phone'],
            ['preferred_channel','Preferred channel',plainLabel],['preferred_language','Language'],
            ['consent_basis','Contact basis'],['do_not_contact','Do not contact']
          ])}<button type="button" class="btn ghost sm" data-edit-contact-profile="${escapeHtml(contact.id)}">Edit contact profile</button></article>`;
      }).join('')}</div>`:CUI.emptyState({iconName:'customers',title:'No contacts',body:'Add the first decision maker, champion, billing contact or technical administrator.'})}
    </section>
    <section class="card platform-detail-section" id="detail-qualification">
      ${sectionHeader('Qualification and discovery',`<button type="button" class="btn ghost sm" data-edit-qualification>${CUI.icon('edit',{size:16})}<span>Record qualification</span></button>`)}
      ${typedDetailHtml(qualification,[
        ['qualification_status','Status',plainLabel],['primary_problem','Primary problem'],['desired_outcome','Desired outcome'],
        ['current_tool_vendor','Current tool / vendor'],['pain_points','Pain points'],['required_features','Required features'],
        ['required_integrations','Required integrations'],['budget_status','Budget',plainLabel],
        ['expected_subscription_cents','Expected subscription',value=>value===undefined?'—':currency(value)],
        ['purchase_timeframe','Purchase timeframe'],['target_go_live','Target go-live'],['decision_date','Decision date'],
        ['main_objection','Main objection'],['risk_level','Risk',plainLabel],['fit_score','Fit score'],
        ['intent_score','Intent score'],['system_suggested_score','System suggestion'],['human_confirmed_score','Human-confirmed score']
      ])}
    </section>
    <section class="card platform-detail-section" id="detail-activities">
      ${sectionHeader('Activities and timeline',`<div class="platform-actions">${['call','whatsapp','email','meeting'].map(type=>`<button type="button" class="btn ghost sm" data-add-activity="${type}">${escapeHtml(type==='meeting'?'Meeting':plainLabel(type))}</button>`).join('')}</div>`)}
      ${activities.length?activities.map(activity=>`<article class="platform-timeline-item"><div class="platform-timeline-marker"></div><div><div class="platform-list-row"><b>${escapeHtml(plainLabel(activity.activity_type||activity.type))}</b><span class="muted small">${escapeHtml(dateTime(activity.occurred_at||activity.created_at))}</span></div><p class="small">${escapeHtml(activity.summary||activity.detail||'')}</p>${Object.keys(asObject(activity.extended_detail)).length?`<p class="muted small">${escapeHtml([activity.extended_detail.outcome,activity.extended_detail.channel&&plainLabel(activity.extended_detail.channel),activity.extended_detail.next_action].filter(Boolean).join(' · '))}</p>`:''}</div></article>`).join(''):detailObjectHtml(null)}
    </section>
    <section class="card platform-detail-section" id="detail-tasks">${sectionHeader('Tasks and next actions')}${tasks.length?tasks.map(task=>`<div class="platform-action-item"><div><b>${escapeHtml(task.title||'Task')}</b><p class="muted small">Due ${escapeHtml(dateTime(task.due_at))} · ${escapeHtml(task.status||'open')}</p></div>${task.status!=='completed'?`<button type="button" class="btn ghost sm" data-complete-task="${escapeHtml(task.id)}">Complete</button>`:''}</div>`).join(''):detailObjectHtml(null)}</section>
    <section class="card platform-detail-section" id="detail-commercial">
      ${sectionHeader('Commercial terms',terms.id?`<button type="button" class="btn ghost sm" data-edit-commercial-detail>Record commercial detail</button>`:'')}
      <div class="platform-detail-grid">
        ${typedDetailHtml(terms,[
          ['product_code','Product'],['plan_code','Plan'],['billing_cycle','Billing cycle',plainLabel],
          ['seats','Seats'],['accepted_value_cents','Accepted value',value=>value===undefined?'—':currency(value,terms.currency)],
          ['contract_status','Contract',plainLabel],['owner_email','Owner email'],['target_go_live','Target go-live']
        ])}
        ${typedDetailHtml(commercialDetail,[
          ['unit_price_cents','Unit price',value=>value===undefined?'—':currency(value,terms.currency)],
          ['discount_basis_points','Discount',value=>value===undefined?'—':`${Number(value)/100}%`],
          ['setup_fee_cents','Setup fee',value=>value===undefined?'—':currency(value,terms.currency)],
          ['tax_treatment','Tax treatment',plainLabel],['contract_term_months','Contract months'],
          ['renewal_on','Renewal date'],['payment_terms_days','Payment terms',value=>value===undefined?'—':`${value} days`],
          ['payment_status','Payment status',plainLabel],['amount_collected_cents','Amount collected',value=>value===undefined?'—':currency(value,terms.currency)]
        ])}
      </div>
    </section>
    <section class="card platform-detail-section" id="detail-documents">
      ${sectionHeader('Documents',`<button type="button" class="btn ghost sm" data-upload-document>${CUI.icon('import',{size:16})}<span>Upload</span></button>`)}
      ${documents.length?documents.map(document=>`<div class="platform-action-item"><div><b>${escapeHtml(document.original_filename)}</b><p class="muted small">${escapeHtml(plainLabel(document.document_type))} · v${escapeHtml(document.version)} · ${escapeHtml(plainLabel(document.status))} · ${escapeHtml(formatFileSize(document.size_bytes))}</p></div>${['uploaded','verified'].includes(document.status)?`<button type="button" class="btn ghost sm" data-read-document="${escapeHtml(document.id)}">Open</button>`:CUI.status(plainLabel(document.status),'off')}</div>`).join(''):CUI.emptyState({iconName:'empty',title:'No documents',body:'Upload proposals, agreements, registration profiles or onboarding material to the private prospect vault.'})}
    </section>
    <section class="card platform-detail-section" id="detail-conversion">
      ${sectionHeader('Conversion and account configuration',`<button type="button" class="btn ghost sm" data-edit-conversion-config>Configure account</button>`)}
      ${typedDetailHtml(conversion,[
        ['workspace_name','Workspace name'],['workspace_slug','Workspace slug'],['owner_email','Owner email'],
        ['seat_limit','Seat limit'],['plan_code','Plan'],['billing_cycle','Billing cycle',plainLabel],
        ['currency','Currency'],['timezone','Timezone'],['locale','Locale'],['data_import_status','Data import',plainLabel],
        ['require_two_factor','Require 2FA'],['customer_success_consultant_id','Customer success owner'],
        ['target_go_live','Target go-live']
      ])}
      ${converted?'':`<p class="platform-route-note small">Current stage: ${escapeHtml(plainLabel(stage))}. ${escapeHtml(stage==='client'?(termsAccepted?'Commercial terms are ready for account creation.':'Accepted commercial terms are required before account creation.'):'Complete the evidence-backed Client gate first.')}</p>`}
    </section>
    <section class="platform-detail-section" id="detail-onboarding">${converted?onboardingPanelHtml(detail.onboarding,detail.onboarding_error,CUI,isSuperAdmin):CUI.card({title:'Onboarding checklist',body:'<p class="muted small">The evidence checklist is created during transactional account conversion.</p>'})}</section>
    <section class="card platform-detail-section" id="detail-audit">
      ${sectionHeader('Audit and stage history')}
      <div class="platform-detail-grid"><div><h3>Stage history</h3>${asArray(detail.stage_history).length?asArray(detail.stage_history).map(history=>`<div class="platform-action-item"><div><b>${escapeHtml(plainLabel(history.to_stage_key))}</b><p class="muted small">${escapeHtml(history.reason_code?plainLabel(history.reason_code):'Stage transition')}</p></div><span class="muted small">${escapeHtml(dateTime(history.occurred_at))}</span></div>`).join(''):detailObjectHtml(null)}</div>
      <div><h3>Recorded gate evidence</h3>${stageEvidence.length?stageEvidence.map(evidence=>`<div class="platform-action-item"><div><b>${escapeHtml(plainLabel(evidence.stage_key))}</b><p class="muted small">${escapeHtml(Object.keys(asObject(evidence.evidence)).join(', '))}</p></div><span class="muted small">${escapeHtml(dateTime(evidence.created_at))}</span></div>`).join(''):detailObjectHtml(null)}</div></div>
      <h3 style="margin-top:14px">Audit events</h3>${audit.length?audit.map(event=>`<div class="platform-action-item"><div><b>${escapeHtml(plainLabel(event.action))}</b><p class="muted small">${escapeHtml(plainLabel(event.entity))}</p></div><span class="muted small">${escapeHtml(dateTime(event.created_at))}</span></div>`).join(''):detailObjectHtml(null)}
    </section>`;
  }
  function wireProspectDetail(detail,context) {
    const {overlay}=context,prospect=asObject(detail.prospect);
    const on=(selector,handler)=>{const target=overlay.querySelector(selector);if(target)target.onclick=handler};
    overlay.querySelectorAll('[data-detail-section]').forEach(button=>button.onclick=()=>{
      overlay.querySelector(`#${button.dataset.detailSection}`)?.scrollIntoView?.({behavior:'smooth',block:'start'});
    });
    on('[data-edit-prospect]',()=>editProspectModal(detail,context));
    on('[data-assign-prospect]',()=>assignProspectModal(prospect,context));
    on('[data-add-note]',()=>activityModal(prospect,'note',context));
    on('[data-add-npu]',()=>activityModal(prospect,'npu',context));
    overlay.querySelectorAll('[data-add-activity]').forEach(button=>button.onclick=()=>activityModal(prospect,button.dataset.addActivity,context));
    on('[data-add-task]',()=>taskModal(prospect,context));
    on('[data-add-contact]',()=>contactModal(detail,null,context));
    overlay.querySelectorAll('[data-edit-contact-profile]').forEach(button=>{
      const contact=asArray(detail.contacts).find(row=>String(contactBase(row).id)===button.dataset.editContactProfile);
      button.onclick=()=>contactModal(detail,contact,context);
    });
    on('[data-edit-company-profile]',()=>companyProfileModal(detail,context));
    on('[data-edit-qualification]',()=>qualificationModal(detail,context));
    on('[data-edit-commercial-detail]',()=>commercialDetailModal(detail,context));
    on('[data-edit-conversion-config]',()=>conversionConfigurationModal(detail,context));
    on('[data-refresh-quality]',()=>refreshProspectQuality(prospect,context));
    overlay.querySelectorAll('[data-upload-document]').forEach(button=>button.onclick=()=>documentUploadModal(detail,context));
    overlay.querySelectorAll('[data-read-document]').forEach(button=>button.onclick=()=>openProspectDocument(button.dataset.readDocument,button,context));
    on('[data-lost]',()=>requestStageMove(prospect,'lost',context));
    on('[data-convert]',()=>requestStageMove(prospect,'client',context));
    on('[data-create-account]',()=>requestAccountConversion(detail,context));
    overlay.querySelectorAll('[data-complete-task]').forEach(button=>button.onclick=()=>completeTaskModal(button.dataset.completeTask,context));
    if(detail.onboarding?.checklist)wireOnboardingChecklist(detail,context);
  }
  const profileValue=(value,key)=>asObject(value)[key]??'';
  const commaValues=value=>Array.isArray(value)?value.join(', '):String(value||'');
  const formList=value=>String(value||'').split(',').map(item=>item.trim()).filter(Boolean);
  const nullableNumber=value=>String(value||'').trim()===''?null:Number(value);
  const nullableDateTime=value=>String(value||'').trim()===''?null:new Date(value).toISOString();
  function isoInput(value,{date=false}={}) {
    if(!value)return'';
    const parsed=new Date(value);
    if(Number.isNaN(parsed.getTime()))return String(value).slice(0,date?10:16);
    if(date)return parsed.toISOString().slice(0,10);
    return new Date(parsed.getTime()-parsed.getTimezoneOffset()*60000).toISOString().slice(0,16);
  }
  function profileSnapshot(source,allowed) {
    const object=asObject(source),result={};
    allowed.forEach(key=>{
      if(Object.prototype.hasOwnProperty.call(object,key))result[key]=object[key];
    });
    return result;
  }
  async function refreshAfterProspectMutation(prospectId,controls,context,message) {
    controls.close();
    context.markBoardDirty?.();
    await refreshProspectDrawer(context,prospectId);
    context.CUI.announce(message);
  }
  function companyProfileModal(detail,context) {
    const {CUI,sb}=context,company=asObject(detail.company),current=asObject(detail.company_profile);
    const arrays=['service_areas','products_services','required_integrations','existing_tools','certifications'];
    modal({title:'Edit company operating profile',submitLabel:'Save profile version',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'companyEntityType',label:'Entity type',value:profileValue(current,'entity_type'),attributes:'name="entity_type"'})}
      ${CUI.field({id:'companyBusinessStatus',label:'Business status',value:profileValue(current,'business_status'),attributes:'name="business_status"'})}
      ${CUI.field({id:'companyIncorporatedOn',label:'Incorporated on',type:'date',value:isoInput(current.incorporated_on,{date:true}),attributes:'name="incorporated_on"'})}
      ${CUI.field({id:'companyPostalCode',label:'Postal code',value:profileValue(current,'postal_code'),attributes:'name="postal_code"'})}
      <div class="wide">${CUI.field({id:'companyRegisteredAddress',label:'Registered address',value:profileValue(current,'registered_address'),attributes:'name="registered_address"'})}</div>
      <div class="wide">${CUI.field({id:'companyOperatingAddress',label:'Operating address',value:profileValue(current,'operating_address'),attributes:'name="operating_address"'})}</div>
      ${CUI.field({id:'companyMainActivity',label:'Main business activity',value:profileValue(current,'main_business_activity'),attributes:'name="main_business_activity"'})}
      ${CUI.field({id:'companySubIndustry',label:'Sub-industry',value:profileValue(current,'sub_industry'),attributes:'name="sub_industry"'})}
      ${CUI.field({id:'companyEmployeeRange',label:'Employee range',value:profileValue(current,'employee_range'),attributes:'name="employee_range"'})}
      ${CUI.field({id:'companyExpectedSeats',label:'Expected seats',type:'number',value:profileValue(current,'expected_seats'),attributes:'name="expected_seats" min="0" step="1"'})}
      ${CUI.field({id:'companyLocationCount',label:'Location count',type:'number',value:profileValue(current,'location_count'),attributes:'name="location_count" min="0" step="1"'})}
      ${CUI.field({id:'companyDigitalMaturity',label:'Digital maturity',control:'select',options:['','low','developing','established','advanced'].map(value=>({value,label:value?plainLabel(value):'Not recorded',selected:value===current.digital_maturity})),attributes:'name="digital_maturity"'})}
      <div class="wide">${CUI.field({id:'companyDescription',label:'Business description',control:'textarea',value:profileValue(current,'business_description'),attributes:'name="business_description" rows="3"'})}</div>
      <div class="wide">${CUI.field({id:'companyServices',label:'Products / services',value:commaValues(current.products_services),hint:'Comma-separated',attributes:'name="products_services"'})}</div>
      <div class="wide">${CUI.field({id:'companyTools',label:'Existing tools',value:commaValues(current.existing_tools),hint:'Comma-separated',attributes:'name="existing_tools"'})}</div>
      <div class="wide">${CUI.field({id:'companyIntegrations',label:'Required integrations',value:commaValues(current.required_integrations),hint:'Comma-separated',attributes:'name="required_integrations"'})}</div>
      <div class="wide">${CUI.field({id:'companyManualWorkflows',label:'Manual workflows to replace',control:'textarea',value:profileValue(current,'manual_workflows'),attributes:'name="manual_workflows" rows="3"'})}</div>
      ${CUI.field({id:'companyVerification',label:'Verification status',control:'select',options:['unverified','verified','disputed'].map(value=>({value,label:plainLabel(value),selected:value===(current.verification_status||'unverified')})),attributes:'name="verification_status"'})}
      <label class="row platform-confirm-row"><input type="checkbox" name="confirmed" value="yes"${current.confirmed_by?' checked':''}><span>Values confirmed with the firm</span></label>
    </div>`,onSubmit:async(form,controls)=>{
      const allowed=[
        'registration_country','entity_type','incorporated_on','business_status','registered_address',
        'operating_address','postal_code','country_code','region_state','service_areas','main_business_activity',
        'secondary_business_activities','sub_industry','business_description','whatsapp_original','social_profiles',
        'directory_profile_url','directory_code','public_rating','public_review_count','rating_source','employee_range',
        'expected_seats','location_count','years_in_business','annual_revenue_band','customer_type','operating_model',
        'products_services','monthly_volume','seasonal_periods','geographic_coverage','internal_languages','existing_tools',
        'existing_crm','existing_accounting','manual_workflows','required_integrations','migration_volume','digital_maturity',
        'technical_capability','procurement_security_requirements','regulatory_compliance_needs','organisation_structure',
        'parent_company','ownership_model','certifications','current_competitors','verification_status','verified_at',
        'verification_notes','source_name','source_url','source_value','captured_at','confirmed_value'
      ];
      const profile={...profileSnapshot(current,allowed)};
      for(const key of ['entity_type','business_status','incorporated_on','postal_code','registered_address','operating_address','main_business_activity','sub_industry','employee_range','digital_maturity','business_description','manual_workflows','verification_status'])profile[key]=form.get(key)||null;
      for(const key of ['expected_seats','location_count'])profile[key]=nullableNumber(form.get(key));
      arrays.forEach(key=>profile[key]=formList(form.get(key)));
      profile.confirmed=form.get('confirmed')==='yes';
      await rpc(sb,'platform_record_company_profile_v86',{p_company:company.id,p_profile:profile});
      await refreshAfterProspectMutation(detail.prospect.id,controls,context,'Company profile saved.');
    }});
  }
  function contactModal(detail,row,context) {
    const {CUI,sb}=context,prospect=asObject(detail.prospect),base=contactBase(row||{}),current=contactExtended(row||{});
    const editing=Boolean(base.id);
    modal({title:editing?'Edit contact':'Add contact',submitLabel:editing?'Save contact':'Add contact',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'contactFullName',label:'Full name',required:true,value:base.full_name||'',attributes:'name="full_name"'})}
      ${CUI.field({id:'contactTitle',label:'Job title',value:base.title||'',attributes:'name="title"'})}
      ${CUI.field({id:'contactEmail',label:'Email',type:'email',value:base.email||'',attributes:'name="email"'})}
      ${CUI.field({id:'contactPhone',label:'Phone',value:base.phone||current.mobile_original||'',attributes:'name="phone"'})}
      ${CUI.field({id:'contactPreferredName',label:'Preferred name',value:current.preferred_name||'',attributes:'name="preferred_name"'})}
      ${CUI.field({id:'contactDepartment',label:'Department / function',value:current.department_function||'',attributes:'name="department_function"'})}
      ${CUI.field({id:'contactDecisionRole',label:'Decision role',control:'select',options:['','decision_maker','champion','influencer','budget_owner','user','gatekeeper'].map(value=>({value,label:value?plainLabel(value):'Not recorded',selected:value===current.decision_role})),attributes:'name="decision_role"'})}
      ${CUI.field({id:'contactPreferredChannel',label:'Preferred channel',control:'select',options:['','phone','whatsapp','email','sms','video','in_person'].map(value=>({value,label:value?plainLabel(value):'Not recorded',selected:value===current.preferred_channel})),attributes:'name="preferred_channel"'})}
      ${CUI.field({id:'contactLanguage',label:'Preferred language',value:current.preferred_language||'',attributes:'name="preferred_language"'})}
      ${CUI.field({id:'contactBasis',label:'Contact basis',value:current.consent_basis||'',hint:'For example: existing customer enquiry or direct business relationship.',attributes:'name="consent_basis"'})}
      <div class="wide">${CUI.field({id:'contactNotes',label:'Contact notes',control:'textarea',value:current.notes||'',attributes:'name="notes" rows="3"'})}</div>
      ${[['is_primary','Primary contact',base.is_primary],['active','Active contact',base.active!==false],['is_billing_contact','Billing contact',current.is_billing_contact],['is_technical_admin','Technical administrator',current.is_technical_admin],['is_authorised_signatory','Authorised signatory',current.is_authorised_signatory],['do_not_contact','Do not contact',current.do_not_contact]].map(([name,label,checked])=>`<label class="row platform-confirm-row"><input type="checkbox" name="${name}" value="yes"${checked?' checked':''}><span>${label}</span></label>`).join('')}
    </div>`,onSubmit:async(form,controls)=>{
      if(!String(form.get('email')||'').trim()&&!String(form.get('phone')||'').trim())throw new Error('Enter an email address or phone number.');
      const basePayload={full_name:form.get('full_name'),title:form.get('title')||null,email:form.get('email')||null,phone:form.get('phone')||null,is_primary:form.get('is_primary')==='yes',active:form.get('active')==='yes'};
      const allowed=['preferred_name','department_function','decision_role','decision_authority_level','mobile_original','office_phone_original','whatsapp_original','preferred_channel','preferred_language','timezone','contact_hours','profile_url','is_billing_contact','is_technical_admin','is_authorised_signatory','consent_basis','marketing_opt_in','opted_in_at','opt_in_source','do_not_contact','last_contacted_at','next_follow_up_at','notes'];
      const profile={...profileSnapshot(current,allowed)};
      for(const key of ['preferred_name','department_function','decision_role','preferred_channel','preferred_language','consent_basis','notes'])profile[key]=form.get(key)||null;
      profile.mobile_original=form.get('phone')||null;
      for(const key of ['is_billing_contact','is_technical_admin','is_authorised_signatory','do_not_contact'])profile[key]=form.get(key)==='yes';
      await rpc(sb,'platform_upsert_prospect_contact_v86',{p_prospect:prospect.id,p_contact:base.id||null,p_base:basePayload,p_profile:profile,p_expected_version:prospectVersion(prospect),p_idempotency_key:idempotencyKey()});
      await refreshAfterProspectMutation(prospect.id,controls,context,editing?'Contact updated.':'Contact added.');
    }});
  }
  function qualificationModal(detail,context) {
    const {CUI,sb}=context,prospect=asObject(detail.prospect),current=asObject(detail.qualification);
    modal({title:'Record qualification and discovery',submitLabel:'Save qualification version',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'qualStatus',label:'Qualification status',control:'select',options:['','unqualified','discovery','qualified','disqualified'].map(value=>({value,label:value?plainLabel(value):'Not recorded',selected:value===current.qualification_status})),attributes:'name="qualification_status"'})}
      ${CUI.field({id:'qualBudget',label:'Budget status',control:'select',options:['','unknown','not_confirmed','range_confirmed','approved','no_budget'].map(value=>({value,label:value?plainLabel(value):'Not recorded',selected:value===current.budget_status})),attributes:'name="budget_status"'})}
      <div class="wide">${CUI.field({id:'qualProblem',label:'Primary problem',control:'textarea',value:current.primary_problem||'',attributes:'name="primary_problem" rows="3"'})}</div>
      <div class="wide">${CUI.field({id:'qualOutcome',label:'Desired outcome',control:'textarea',value:current.desired_outcome||'',attributes:'name="desired_outcome" rows="3"'})}</div>
      ${CUI.field({id:'qualCurrentVendor',label:'Current tool / vendor',value:current.current_tool_vendor||'',attributes:'name="current_tool_vendor"'})}
      ${CUI.field({id:'qualTimeframe',label:'Purchase timeframe',value:current.purchase_timeframe||'',attributes:'name="purchase_timeframe"'})}
      ${CUI.field({id:'qualExpectedSubscription',label:'Expected subscription (cents)',type:'number',value:current.expected_subscription_cents??'',attributes:'name="expected_subscription_cents" min="0" step="1"'})}
      ${CUI.field({id:'qualExpectedSetup',label:'Expected setup fee (cents)',type:'number',value:current.expected_setup_fee_cents??'',attributes:'name="expected_setup_fee_cents" min="0" step="1"'})}
      ${CUI.field({id:'qualGoLive',label:'Target go-live',type:'date',value:isoInput(current.target_go_live,{date:true}),attributes:'name="target_go_live"'})}
      ${CUI.field({id:'qualDecisionDate',label:'Decision date',type:'date',value:isoInput(current.decision_date,{date:true}),attributes:'name="decision_date"'})}
      ${CUI.field({id:'qualRisk',label:'Risk level',control:'select',options:['','low','medium','high'].map(value=>({value,label:value?plainLabel(value):'Not recorded',selected:value===current.risk_level})),attributes:'name="risk_level"'})}
      ${CUI.field({id:'qualFit',label:'Fit score (0–100)',type:'number',value:current.fit_score??'',attributes:'name="fit_score" min="0" max="100" step="1"'})}
      ${CUI.field({id:'qualIntent',label:'Intent score (0–100)',type:'number',value:current.intent_score??'',attributes:'name="intent_score" min="0" max="100" step="1"'})}
      ${CUI.field({id:'qualHumanScore',label:'Human-confirmed score (0–100)',type:'number',value:current.human_confirmed_score??'',attributes:'name="human_confirmed_score" min="0" max="100" step="1"'})}
      <div class="wide">${CUI.field({id:'qualPain',label:'Pain points',value:commaValues(current.pain_points),hint:'Comma-separated',attributes:'name="pain_points"'})}</div>
      <div class="wide">${CUI.field({id:'qualFeatures',label:'Required features',value:commaValues(current.required_features),hint:'Comma-separated',attributes:'name="required_features"'})}</div>
      <div class="wide">${CUI.field({id:'qualIntegrations',label:'Required integrations',value:commaValues(current.required_integrations),hint:'Comma-separated',attributes:'name="required_integrations"'})}</div>
      <div class="wide">${CUI.field({id:'qualObjection',label:'Main objection',control:'textarea',value:current.main_objection||'',attributes:'name="main_objection" rows="3"'})}</div>
    </div>`,onSubmit:async(form,controls)=>{
      const allowed=['primary_problem','why_change','existing_workflow','current_tool_vendor','pain_points','consequence_of_inaction','desired_outcome','required_features','nice_to_have_features','success_criteria','expected_user_count','expected_usage_volume','required_integrations','required_migration','security_requirements','compliance_requirements','decision_maker_contact_id','champion_contact_id','budget_owner_contact_id','budget_status','budget_min_cents','budget_max_cents','expected_subscription_cents','expected_setup_fee_cents','purchase_timeframe','target_go_live','procurement_process','legal_review_required','security_review_required','competitors_considered','decision_criteria','decision_date','main_objection','risk_level','fit_score','intent_score','qualification_status','disqualification_reason','system_suggested_score','score_reasons','human_confirmed_score'];
      const profile={...profileSnapshot(current,allowed)};
      for(const key of ['qualification_status','budget_status','primary_problem','desired_outcome','current_tool_vendor','purchase_timeframe','target_go_live','decision_date','risk_level','main_objection'])profile[key]=form.get(key)||null;
      for(const key of ['expected_subscription_cents','expected_setup_fee_cents','fit_score','intent_score','human_confirmed_score'])profile[key]=nullableNumber(form.get(key));
      for(const key of ['pain_points','required_features','required_integrations'])profile[key]=formList(form.get(key));
      await rpc(sb,'platform_record_qualification_v86',{p_prospect:prospect.id,p_profile:profile});
      await refreshAfterProspectMutation(prospect.id,controls,context,'Qualification saved.');
    }});
  }
  function commercialDetailModal(detail,context) {
    const {CUI,sb}=context,prospect=asObject(detail.prospect),terms=commercialBase(detail.commercial_terms);
    const current=commercialExtended(detail.commercial_terms);
    if(!terms.id){CUI.announce('Record commercial terms at the Client stage first.',{assertive:true});return}
    modal({title:'Record commercial detail',submitLabel:'Save commercial version',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'commercialUnitPrice',label:'Unit price (cents)',type:'number',value:current.unit_price_cents??'',attributes:'name="unit_price_cents" min="0" step="1"'})}
      ${CUI.field({id:'commercialDiscount',label:'Discount (basis points)',type:'number',value:current.discount_basis_points??'',attributes:'name="discount_basis_points" min="0" max="10000" step="1"'})}
      <div class="wide">${CUI.field({id:'commercialDiscountReason',label:'Discount reason',value:current.discount_reason||'',attributes:'name="discount_reason"'})}</div>
      ${CUI.field({id:'commercialSetupFee',label:'Setup fee (cents)',type:'number',value:current.setup_fee_cents??'',attributes:'name="setup_fee_cents" min="0" step="1"'})}
      ${CUI.field({id:'commercialContractMonths',label:'Contract term (months)',type:'number',value:current.contract_term_months??'',attributes:'name="contract_term_months" min="1" step="1"'})}
      ${CUI.field({id:'commercialTax',label:'Tax treatment',control:'select',options:['','exclusive','inclusive','exempt'].map(value=>({value,label:value?plainLabel(value):'Not recorded',selected:value===current.tax_treatment})),attributes:'name="tax_treatment"'})}
      ${CUI.field({id:'commercialTermsDays',label:'Payment terms (days)',type:'number',value:current.payment_terms_days??'',attributes:'name="payment_terms_days" min="0" step="1"'})}
      ${CUI.field({id:'commercialRenewal',label:'Renewal date',type:'date',value:isoInput(current.renewal_on,{date:true}),attributes:'name="renewal_on"'})}
      ${CUI.field({id:'commercialSubStatus',label:'Subscription status',control:'select',options:['','proposal','trial','active','past_due','cancelled'].map(value=>({value,label:value?plainLabel(value):'Not recorded',selected:value===current.subscription_status})),attributes:'name="subscription_status"'})}
      ${CUI.field({id:'commercialPaymentStatus',label:'Payment status',control:'select',options:['','unpaid','partially_paid','paid','refunded','charged_back'].map(value=>({value,label:value?plainLabel(value):'Not recorded',selected:value===current.payment_status})),attributes:'name="payment_status"'})}
      ${CUI.field({id:'commercialCollected',label:'Amount collected (cents)',type:'number',value:current.amount_collected_cents??'',attributes:'name="amount_collected_cents" min="0" step="1"'})}
      ${CUI.field({id:'commercialFirstPaid',label:'First payment at',type:'datetime-local',value:isoInput(current.first_payment_at),attributes:'name="first_payment_at"'})}
      ${CUI.field({id:'commercialProposalVersion',label:'Proposal version',value:current.proposal_version||'',attributes:'name="proposal_version"'})}
      <label class="row platform-confirm-row"><input type="checkbox" name="purchase_order_required" value="yes"${current.purchase_order_required?' checked':''}><span>Purchase order required</span></label>
      ${CUI.field({id:'commercialPo',label:'Purchase order number',value:current.purchase_order_number||'',attributes:'name="purchase_order_number"'})}
    </div>`,onSubmit:async(form,controls)=>{
      const allowed=['unit_price_cents','discount_basis_points','discount_reason','discount_approved_by','tax_treatment','setup_fee_cents','contract_term_months','trial_starts_on','trial_ends_on','subscription_starts_on','subscription_ends_on','renewal_on','payment_terms_days','proposal_version','proposal_sent_at','proposal_expires_at','contract_sent_at','contract_signed_at','signatory_contact_id','purchase_order_required','purchase_order_number','subscription_status','payment_status','first_payment_at','amount_collected_cents'];
      const profile={...profileSnapshot(current,allowed)};
      for(const key of ['discount_reason','tax_treatment','renewal_on','subscription_status','payment_status','proposal_version','purchase_order_number'])profile[key]=form.get(key)||null;
      for(const key of ['unit_price_cents','discount_basis_points','setup_fee_cents','contract_term_months','payment_terms_days','amount_collected_cents'])profile[key]=nullableNumber(form.get(key));
      profile.first_payment_at=nullableDateTime(form.get('first_payment_at'));
      profile.purchase_order_required=form.get('purchase_order_required')==='yes';
      await rpc(sb,'platform_record_commercial_detail_v86',{p_commercial_terms:terms.id,p_detail:profile});
      await refreshAfterProspectMutation(prospect.id,controls,context,'Commercial detail saved.');
    }});
  }
  function conversionConfigurationModal(detail,context) {
    const {CUI,sb}=context,prospect=asObject(detail.prospect),company=asObject(detail.company);
    const current=asObject(detail.conversion_configuration),primary=contactBase(asArray(detail.contacts).find(row=>contactBase(row).is_primary)||{});
    modal({title:'Configure the future Nestly account',submitLabel:'Save configuration version',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'configWorkspaceName',label:'Workspace name',required:true,value:current.workspace_name||company.trading_name||company.legal_name||'',attributes:'name="workspace_name"'})}
      ${CUI.field({id:'configWorkspaceSlug',label:'Workspace slug',value:current.workspace_slug||'',attributes:'name="workspace_slug" pattern="[a-z0-9-]+"'})}
      ${CUI.field({id:'configOwnerEmail',label:'Owner email',type:'email',required:true,value:current.owner_email||primary.email||'',attributes:'name="owner_email"'})}
      ${CUI.field({id:'configOwnerPhone',label:'Owner phone',value:current.owner_phone||primary.phone||'',attributes:'name="owner_phone"'})}
      ${CUI.field({id:'configPlan',label:'Plan',value:current.plan_code||commercialBase(detail.commercial_terms).plan_code||'',attributes:'name="plan_code"'})}
      ${CUI.field({id:'configCadence',label:'Billing cycle',control:'select',options:['quarterly','half_yearly','annual'].map(value=>({value,label:plainLabel(value),selected:value===(current.billing_cycle||commercialBase(detail.commercial_terms).billing_cycle)})),attributes:'name="billing_cycle"'})}
      ${CUI.field({id:'configSeats',label:'Seat limit',type:'number',value:current.seat_limit??commercialBase(detail.commercial_terms).seats??1,attributes:'name="seat_limit" min="1" step="1"'})}
      ${CUI.field({id:'configCurrency',label:'Currency',value:current.currency||commercialBase(detail.commercial_terms).currency||'SGD',attributes:'name="currency" maxlength="3"'})}
      ${CUI.field({id:'configTimezone',label:'Timezone',value:current.timezone||'Asia/Singapore',attributes:'name="timezone"'})}
      ${CUI.field({id:'configLocale',label:'Locale',value:current.locale||'en-SG',attributes:'name="locale"'})}
      ${CUI.field({id:'configDataImport',label:'Data import status',control:'select',options:['not_started','template_sent','received','validated','completed','not_required'].map(value=>({value,label:plainLabel(value),selected:value===(current.data_import_status||'not_started')})),attributes:'name="data_import_status"'})}
      ${CUI.field({id:'configTargetGoLive',label:'Target go-live',type:'date',value:isoInput(current.target_go_live||commercialBase(detail.commercial_terms).target_go_live,{date:true}),attributes:'name="target_go_live"'})}
      <div class="wide">${CUI.field({id:'configIntegrations',label:'Required integrations',value:commaValues(current.required_integrations),hint:'Comma-separated',attributes:'name="required_integrations"'})}</div>
      <div class="wide">${CUI.field({id:'configWelcome',label:'Welcome message',control:'textarea',value:current.welcome_message||'',attributes:'name="welcome_message" rows="3"'})}</div>
      <label class="row platform-confirm-row"><input type="checkbox" name="require_two_factor" value="yes"${current.require_two_factor?' checked':''}><span>Require two-factor authentication</span></label>
    </div>`,onSubmit:async(form,controls)=>{
      const allowed=['workspace_name','legal_name','registration_number','workspace_slug','primary_owner_contact_id','owner_email','owner_phone','administrator_emails','team_member_emails','role_template_key','seat_limit','plan_code','billing_cycle','trial_starts_on','trial_ends_on','billing_contact_id','invoice_address','gst_registration_number','invoice_prefix','currency','timezone','locale','date_format','logo_document_id','brand_primary_color','brand_secondary_color','sender_name','welcome_message','custom_domain','default_terms_document_id','payment_instructions_masked','workflow_template_key','notification_preferences','required_integrations','data_import_status','security_policy','require_two_factor','retention_policy_days','support_owner','customer_success_consultant_id','target_go_live'];
      const profile={...profileSnapshot(current,allowed)};
      for(const key of ['workspace_name','workspace_slug','owner_email','owner_phone','plan_code','billing_cycle','currency','timezone','locale','data_import_status','target_go_live','welcome_message'])profile[key]=form.get(key)||null;
      profile.legal_name=company.legal_name||null;profile.registration_number=company.registration_number||null;
      profile.primary_owner_contact_id=primary.id||null;profile.seat_limit=nullableNumber(form.get('seat_limit'));
      profile.required_integrations=formList(form.get('required_integrations'));
      profile.require_two_factor=form.get('require_two_factor')==='yes';
      await rpc(sb,'platform_record_conversion_configuration_v86',{p_prospect:prospect.id,p_configuration:profile});
      await refreshAfterProspectMutation(prospect.id,controls,context,'Account configuration saved.');
    }});
  }
  async function refreshProspectQuality(prospect,context) {
    const button=context.overlay.querySelector('[data-refresh-quality]');
    if(button)button.disabled=true;
    try{
      await rpc(context.sb,'platform_refresh_prospect_quality_v86',{p_prospect:prospect.id});
      context.markBoardDirty?.();
      await refreshProspectDrawer(context,prospect.id);
      context.CUI.announce('Data-quality score refreshed.');
    }catch(error){
      context.CUI.announce(error.message||'Quality refresh failed.',{assertive:true});
      if(button?.isConnected)button.disabled=false;
    }
  }
  const prospectDocumentTypes=[
    'company_registration','company_profile','accreditation','proposal','signed_agreement',
    'purchase_order','data_processing_agreement','security_questionnaire','migration_template',
    'price_catalogue','branding_asset','implementation_note','other'
  ];
  const prospectDocumentMimes=[
    'application/pdf','text/csv','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'image/png','image/jpeg','image/webp','application/zip'
  ];
  async function invokeDocumentSigner(sb,body) {
    if(!sb.functions?.invoke)throw new Error('The private document signer is unavailable.');
    const result=await sb.functions.invoke('sme-document-signer',{body});
    if(result?.error)throw result.error;
    return asObject(result?.data);
  }
  function documentUploadModal(detail,context) {
    const {CUI,sb}=context,prospect=asObject(detail.prospect);
    modal({title:'Upload private prospect document',submitLabel:'Reserve and upload',CUI,body:`
      ${CUI.field({id:'documentType',label:'Document type',control:'select',options:prospectDocumentTypes.map(value=>({value,label:plainLabel(value)})),attributes:'name="document_type"'})}
      <div class="cui-field"><label for="prospectDocumentFile">File</label><input id="prospectDocumentFile" name="file" type="file" required accept=".pdf,.csv,.xlsx,.png,.jpg,.jpeg,.webp,.zip"><p class="muted small">PDF, CSV, XLSX, PNG, JPEG, WebP or ZIP · maximum 25 MB.</p></div>
      ${CUI.field({id:'documentNotes',label:'Notes',control:'textarea',attributes:'name="notes" rows="3"'})}
      <div class="platform-upload-progress" data-upload-progress aria-live="polite"></div>`,
      onSubmit:async(form,controls)=>{
        const file=form.get('file');
        if(!(file instanceof File)||!file.size)throw new Error('Choose a file to upload.');
        if(file.size>26214400)throw new Error('The file exceeds the 25 MB limit.');
        if(!prospectDocumentMimes.includes(file.type))throw new Error('This file type is not supported.');
        const progress=controls.overlay.querySelector('[data-upload-progress]');
        progress.innerHTML='<p class="muted small">1 of 4 · Reserving the private object path…</p>';
        const reservation=asObject(await rpc(sb,'platform_request_prospect_document_upload_v86',{
          p_prospect:prospect.id,p_document_type:form.get('document_type'),
          p_original_filename:file.name,p_mime_type:file.type,p_size_bytes:file.size,
          p_logical_document:null,p_notes:form.get('notes')||null
        }));
        progress.innerHTML='<p class="muted small">2 of 4 · Exchanging the short-lived upload request…</p>';
        const exchange=await invokeDocumentSigner(sb,{
          action:'exchange',request_id:reservation.request_id,exchange_token:reservation.exchange_token
        });
        if(exchange.purpose!=='upload'||!exchange.signed_upload_token)throw new Error('The signer did not return an upload token.');
        if(exchange.mime_type!==file.type||Number(exchange.size_bytes)!==file.size)throw new Error('The signed reservation no longer matches the selected file.');
        if(new Date(exchange.reservation_expires_at).getTime()<=Date.now())throw new Error('The upload reservation expired. Choose the file and try again.');
        progress.innerHTML='<p class="muted small">3 of 4 · Uploading directly to the private document vault…</p>';
        const storageResult=await sb.storage.from(exchange.bucket_id).uploadToSignedUrl(
          exchange.object_path,exchange.signed_upload_token,file,{contentType:file.type,cacheControl:'0'}
        );
        if(storageResult?.error)throw storageResult.error;
        progress.innerHTML='<p class="muted small">4 of 4 · Verifying the stored object and finalising its record…</p>';
        await invokeDocumentSigner(sb,{action:'finalize',request_id:reservation.request_id});
        await refreshAfterProspectMutation(prospect.id,controls,context,'Private document uploaded and verified.');
      }
    });
  }
  async function openProspectDocument(documentVersion,button,context) {
    button.disabled=true;
    const pendingTab=globalObject.open?.('about:blank','_blank','noopener,noreferrer')||null;
    try{
      const reservation=asObject(await rpc(context.sb,'platform_request_prospect_document_read_v86',{
        p_document_version:documentVersion
      }));
      const exchange=await invokeDocumentSigner(context.sb,{
        action:'exchange',request_id:reservation.request_id,exchange_token:reservation.exchange_token
      });
      if(exchange.purpose!=='read'||!exchange.signed_url)throw new Error('The signer did not return a read URL.');
      if(pendingTab){
        pendingTab.opener=null;
        pendingTab.location.replace(exchange.signed_url);
        context.CUI.announce('Private document opened in a new tab.');
      }else{
        showResultModal({
          title:'Private document is ready',CUI:context.CUI,
          body:`<div class="platform-route-note"><div><b>Your browser blocked the automatic tab</b><p class="small">Use this short-lived link before it expires. The private storage path is not displayed.</p><a class="btn" href="${escapeHtml(exchange.signed_url)}" target="_blank" rel="noopener noreferrer">Open private document</a></div></div>`
        });
        context.CUI.announce('Use the open-document link in the dialog.');
      }
    }catch(error){
      try{pendingTab?.close()}catch(_closeError){}
      context.CUI.announce(error.message||'The document could not be opened.',{assertive:true});
    }finally{if(button.isConnected)button.disabled=false}
  }
  function showResultModal({title,body,CUI}) {
    modal({
      title,submitLabel:'Close',CUI,body,
      onSubmit:async(_form,controls)=>controls.close()
    });
  }
  function showOneTimeInvitation(invitation,context) {
    const {CUI}=context,token=String(invitation?.raw_token||'');
    if(!token)return;
    const overlay=modal({
      title:'Save this owner invitation token',
      submitLabel:'I have saved it',
      CUI,
      body:`<div class="platform-route-note platform-status-note">${CUI.icon('info',{size:19})}<div><b>Shown once</b><p class="small">For privacy, Nestly will not show this full token again. Save it now and share it only with ${escapeHtml(invitation.owner_email||'the workspace owner')}.</p></div></div>
        <label for="ownerInvitationToken">Invitation token</label>
        <div class="row"><input id="ownerInvitationToken" value="${escapeHtml(token)}" readonly spellcheck="false" style="font-family:monospace"><button type="button" class="btn ghost" data-copy-token>Copy token</button></div>
        <p class="muted small" data-copy-status aria-live="polite">The invitation expires ${escapeHtml(dateTime(invitation.expires_at))}.</p>`,
      onSubmit:async(_form,controls)=>controls.close()
    });
    overlay.querySelector('[data-copy-token]').onclick=async()=>{
      const input=overlay.querySelector('#ownerInvitationToken');
      let copied=false;
      try{
        if(globalObject.navigator?.clipboard?.writeText){
          await globalObject.navigator.clipboard.writeText(token);copied=true;
        }else{
          input.select();copied=Boolean(document.execCommand?.('copy'));
        }
      }catch(_error){copied=false}
      overlay.querySelector('[data-copy-status]').textContent=copied
        ?'Token copied. Keep it in a secure handoff channel.'
        :'Copy was unavailable. Select the token and copy it manually.';
    };
  }
  function requestAccountConversion(detail,context) {
    const {CUI,sb}=context,prospect=asObject(detail.prospect),company=asObject(detail.company);
    const terms=asObject(detail.commercial_terms);
    previewThenConfirm({
      title:'Create Nestly account',
      preview:{
        action:'Create an inactive Nestly workspace and evidence checklist',
        prospect_id:prospect.id,
        prospect_version:prospectVersion(prospect),
        company:{legal_name:company.legal_name,trading_name:company.trading_name,registration_number:company.registration_number,sector:company.sector_key||company.industry},
        commercial_terms:{version:terms.version,status:terms.contract_status,owner_email:terms.owner_email,plan_code:terms.plan_code,product_code:terms.product_code,seats:terms.seats,billing_cycle:terms.billing_cycle}
      },
      CUI,
      onConfirm:async controls=>{
        const result=asObject(await rpc(sb,'convert_sme_prospect_v79',{
          p_prospect:prospect.id,
          p_expected_version:prospectVersion(prospect),
          p_idempotency_key:idempotencyKey()
        }));
        controls.close();context.close?.();
        await renderOnboarding(context);
        if(result.outcome==='duplicate_workspace'){
          showResultModal({
            title:'Existing firm matched',
            CUI,
            body:`<div class="platform-route-note platform-status-note">${CUI.icon('info',{size:19})}<div><b>No workspace was created</b><p class="small">This prospect matches existing firm ${escapeHtml(result.matched_business_id||'—')} by ${escapeHtml(plainLabel(result.match_basis))}. Review the match before any manual decision.</p></div></div>`
          });
          CUI.announce('Existing firm matched. No workspace was created.',{assertive:true});
          return;
        }
        CUI.announce(result.outcome==='already_converted'?'The Nestly account already exists.':'Nestly account created. Save the owner invitation token.');
        if(result.owner_invitation?.raw_token)showOneTimeInvitation(result.owner_invitation,context);
      }
    });
  }
  async function finishOnboardingMutation(detail,context,message) {
    context.markBoardDirty?.();
    await refreshProspectDrawer(context,detail.prospect.id);
    context.CUI.announce(message);
  }
  async function runChecklistButton(button,detail,context,name,args,message) {
    button.disabled=true;
    try{
      await rpc(context.sb,name,{...args,p_idempotency_key:idempotencyKey()});
      await finishOnboardingMutation(detail,context,message);
    }catch(error){
      context.CUI.announce(error.message||'The onboarding action could not be completed.',{assertive:true});
      if(button.isConnected)button.disabled=false;
    }
  }
  function wireOnboardingChecklist(detail,context) {
    const {overlay,CUI,sb}=context,onboarding=asObject(detail.onboarding);
    const facts=onboardingFacts(onboarding),businessId=detail.prospect.converted_business_id;
    const expected={p_business:businessId,p_expected_version:facts.version};
    const one=(selector,handler)=>{const target=overlay.querySelector(selector);if(target)target.onclick=()=>handler(target)};
    one('[data-onboarding-refresh]',button=>runChecklistButton(
      button,detail,context,'refresh_business_onboarding_v79',expected,'Onboarding evidence refreshed.'
    ));
    one('[data-onboarding-start]',()=>previewThenConfirm({
      title:'Start onboarding',
      preview:{business_id:businessId,checklist_version:facts.version,action:'Move Account Created to Onboarding in Progress after owner access is accepted'},
      CUI,
      onConfirm:async controls=>{
        await rpc(sb,'start_business_onboarding_v79',{
          ...expected,p_idempotency_key:idempotencyKey()
        });
        controls.close();await finishOnboardingMutation(detail,context,'Onboarding started.');
      }
    }));
    one('[data-onboarding-reissue]',()=>reissueOwnerInvitationModal(detail,context));
    one('[data-onboarding-block]',()=>blockOnboardingModal(detail,null,context));
    one('[data-onboarding-unblock]',()=>unblockOnboarding(detail,null,context));
    one('[data-onboarding-activate]',()=>previewThenConfirm({
      title:'Activate firm',
      preview:{business_id:businessId,checklist_version:facts.version,action:'Activate the default branch and move the prospect to Activated',readiness:facts.status},
      CUI,
      onConfirm:async controls=>{
        await rpc(sb,'activate_business_v79',{
          ...expected,p_idempotency_key:idempotencyKey()
        });
        controls.close();await finishOnboardingMutation(detail,context,'Firm activated.');
      }
    }));
    overlay.querySelectorAll('[data-onboarding-evidence]').forEach(button=>{
      button.onclick=()=>recordOnboardingEvidenceModal(detail,button.dataset.onboardingEvidence,context);
    });
    overlay.querySelectorAll('[data-onboarding-waive]').forEach(button=>{
      button.onclick=()=>waiveOnboardingItemModal(detail,button.dataset.onboardingWaive,context);
    });
    overlay.querySelectorAll('[data-onboarding-item-block]').forEach(button=>{
      button.onclick=()=>blockOnboardingModal(detail,button.dataset.onboardingItemBlock,context);
    });
    overlay.querySelectorAll('[data-onboarding-item-unblock]').forEach(button=>{
      button.onclick=()=>unblockOnboarding(detail,button.dataset.onboardingItemUnblock,context);
    });
  }
  function reissueOwnerInvitationModal(detail,context) {
    const {CUI,sb}=context,onboarding=asObject(detail.onboarding);
    const latest=asArray(onboarding.owner_invitations)[0]||{};
    modal({
      title:'Reissue owner invitation',
      submitLabel:'Reissue and show token',
      CUI,
      body:`${CUI.field({id:'reissueOwnerEmail',label:'Owner email',type:'email',value:latest.owner_email||'',required:true,attributes:'name="owner_email"'})}
        <p class="muted small">Any pending invitation will be revoked. The replacement token is shown once.</p>`,
      onSubmit:async(form,controls)=>{
        const result=asObject(await rpc(sb,'reissue_workspace_owner_invite_v79',{
          p_business:detail.prospect.converted_business_id,
          p_owner_email:form.get('owner_email'),
          p_idempotency_key:idempotencyKey()
        }));
        controls.close();await finishOnboardingMutation(detail,context,'Owner invitation reissued. Save the new token.');
        if(result.owner_invitation?.raw_token)showOneTimeInvitation(result.owner_invitation,context);
      }
    });
  }
  function recordOnboardingEvidenceModal(detail,itemKey,context) {
    const {CUI,sb}=context,facts=onboardingFacts(detail.onboarding);
    const item=asArray(detail.onboarding.items).find(row=>row.item_key===itemKey)||{};
    modal({
      title:`Record evidence · ${item.label||plainLabel(itemKey)}`,
      submitLabel:'Record evidence',
      CUI,
      body:`${CUI.field({id:'onboardingEvidenceNote',label:'Evidence note',control:'textarea',required:true,attributes:'name="note" rows="4"'})}
        ${CUI.field({id:'onboardingEvidenceReference',label:'Reference',hint:'Optional ticket, document or meeting reference.',attributes:'name="reference"'})}`,
      onSubmit:async(form,controls)=>{
        const evidence={note:form.get('note'),recorded_via:'platform_console'};
        if(form.get('reference'))evidence.reference=form.get('reference');
        await rpc(sb,'record_onboarding_manual_evidence_v79',{
          p_business:detail.prospect.converted_business_id,
          p_item_key:itemKey,
          p_evidence:evidence,
          p_expected_version:facts.version,
          p_idempotency_key:idempotencyKey()
        });
        controls.close();await finishOnboardingMutation(detail,context,'Onboarding evidence recorded.');
      }
    });
  }
  function waiveOnboardingItemModal(detail,itemKey,context) {
    const {CUI,sb}=context,facts=onboardingFacts(detail.onboarding);
    const item=asArray(detail.onboarding.items).find(row=>row.item_key===itemKey)||{};
    if(item.waivable!==true||item.item_key==='go_live_approved'){
      CUI.announce('This onboarding item cannot be waived.',{assertive:true});return;
    }
    modal({
      title:`Waive · ${item.label||plainLabel(itemKey)}`,
      submitLabel:'Waive item',
      CUI,
      body:CUI.field({id:'onboardingWaiverReason',label:'Waiver reason',control:'textarea',required:true,attributes:'name="reason" rows="4" minlength="3"'}),
      onSubmit:async(form,controls)=>{
        await rpc(sb,'waive_onboarding_item_v79',{
          p_business:detail.prospect.converted_business_id,
          p_item_key:itemKey,
          p_reason:form.get('reason'),
          p_expected_version:facts.version,
          p_idempotency_key:idempotencyKey()
        });
        controls.close();await finishOnboardingMutation(detail,context,'Onboarding item waived.');
      }
    });
  }
  function blockOnboardingModal(detail,itemKey,context) {
    const {CUI,sb}=context,facts=onboardingFacts(detail.onboarding);
    const label=itemKey?(asArray(detail.onboarding.items).find(row=>row.item_key===itemKey)?.label||plainLabel(itemKey)):'whole onboarding';
    modal({
      title:`Block ${label}`,
      submitLabel:'Block',
      CUI,
      body:CUI.field({id:'onboardingBlockReason',label:'Blocking reason',control:'textarea',required:true,attributes:'name="reason" rows="4" minlength="3"'}),
      onSubmit:async(form,controls)=>{
        await rpc(sb,'block_business_onboarding_v79',{
          p_business:detail.prospect.converted_business_id,
          p_item_key:itemKey,
          p_reason:form.get('reason'),
          p_expected_version:facts.version,
          p_idempotency_key:idempotencyKey()
        });
        controls.close();await finishOnboardingMutation(detail,context,'Onboarding blocked.');
      }
    });
  }
  function unblockOnboarding(detail,itemKey,context) {
    const facts=onboardingFacts(detail.onboarding);
    previewThenConfirm({
      title:itemKey?'Unblock checklist item':'Unblock onboarding',
      preview:{business_id:detail.prospect.converted_business_id,item_key:itemKey,checklist_version:facts.version},
      CUI:context.CUI,
      onConfirm:async controls=>{
        await rpc(context.sb,'unblock_business_onboarding_v79',{
          p_business:detail.prospect.converted_business_id,
          p_item_key:itemKey,
          p_expected_version:facts.version,
          p_idempotency_key:idempotencyKey()
        });
        controls.close();await finishOnboardingMutation(detail,context,'Onboarding unblocked.');
      }
    });
  }
  function editProspectModal(detail,context) {
    const {CUI,sb}=context,prospect=asObject(detail.prospect),company=asObject(detail.company);
    modal({title:'Edit prospect',submitLabel:'Save changes',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'editLegalName',label:'Legal name',value:company.legal_name||'',required:true,attributes:'name="legal_name"'})}
      ${CUI.field({id:'editTradingName',label:'Trading name',value:company.trading_name||'',attributes:'name="trading_name"'})}
      ${CUI.field({id:'editRegistration',label:'UEN / registration',value:company.registration_number||'',attributes:'name="registration_number"'})}
      ${CUI.field({id:'editEmail',label:'Company email',type:'email',value:company.email||'',attributes:'name="email"'})}
      ${CUI.field({id:'editPhone',label:'Company phone',value:company.phone||'',attributes:'name="phone"'})}
      ${CUI.field({id:'editNextAction',label:'Next action at',type:'datetime-local',value:prospect.next_action_at?String(prospect.next_action_at).slice(0,16):'',attributes:'name="next_action_at"'})}
      ${CUI.field({id:'editPriority',label:'Priority',control:'select',options:['low','normal','high','urgent'].map(value=>({value,label:plainLabel(value),selected:value===(prospect.priority||'normal')})),attributes:'name="priority"'})}
      ${CUI.field({id:'editRegion',label:'Region',value:prospect.region||'',attributes:'name="region"'})}
      <div class="wide">${CUI.field({id:'editTags',label:'Tags',value:asArray(detail.tags).map(tag=>tag.tag_key||tag.name||tag).join(', '),attributes:'name="tags"'})}</div>
    </div>`,onSubmit:async(form,controls)=>{
      const patch={
        legal_name:form.get('legal_name'),trading_name:form.get('trading_name')||null,
        registration_number:form.get('registration_number')||null,email:form.get('email')||null,
        phone:form.get('phone')||null,next_action_at:form.get('next_action_at')?new Date(form.get('next_action_at')).toISOString():null,
        priority:form.get('priority')||null,region:form.get('region')||null,
        tags:String(form.get('tags')||'').split(',').map(value=>value.trim()).filter(Boolean)
      };
      await rpc(sb,'platform_update_prospect_v76',{p_prospect:prospect.id,p_expected_version:prospectVersion(prospect),p_patch:patch,p_idempotency_key:idempotencyKey()});
      controls.close();context.close?.();await renderOnboarding(context);CUI.announce('Prospect updated.');
    }});
  }
  async function assignProspectModal(prospect,context) {
    const {CUI,sb}=context;
    const payload=asObject(await rpc(sb,'platform_list_assignment_consultants_v89'));
    const consultants=scopedConsultantOptions(asArray(payload,['items']));
    modal({title:'Assign consultant',submitLabel:'Assign',CUI,body:`${CUI.field({
      id:'assignConsultant',label:'Sales consultant',control:'select',
      options:[{value:'',label:'Unassigned'},...consultants].map(option=>({
        ...option,selected:String(option.value)===String(prospect.assigned_consultant_id||'')
      })),attributes:'name="consultant"'
    })}<p class="muted small">Choose by consultant name. Assignment changes are recorded in the prospect history.</p>`,
      onSubmit:async(form,controls)=>{
        await rpc(sb,'platform_assign_prospect_v89',{
          p_prospect:prospect.id,p_consultant:form.get('consultant')||null,
          p_reason:'admin assignment from enterprise onboarding'
        });
        controls.close();context.close?.();await renderOnboarding(context);CUI.announce('Prospect assignment updated.');
      }});
  }
  function activityModal(prospect,type,context) {
    const {CUI,sb}=context;
    const actualType=type==='npu'?'call':type;
    const defaultSummary=type==='npu'?'No pick-up attempt':type==='meeting'?'Meeting scheduled':'';
    modal({title:type==='npu'?'Record NPU':`Record ${plainLabel(type)}`,submitLabel:'Save activity',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'activityType',label:'Activity type',control:'select',options:['note','call','email','whatsapp','meeting','demo','document_sent','proposal_sent','contract_sent','payment','onboarding_session'].map(value=>({value,label:plainLabel(value),selected:value===actualType})),attributes:'name="activity_type"'})}
      ${CUI.field({id:'activityChannel',label:'Channel',control:'select',options:['','phone','sms','whatsapp','email','video','in_person'].map(value=>({value,label:value?plainLabel(value):'Not recorded',selected:value===actualType||(actualType==='call'&&value==='phone')})),attributes:'name="channel"'})}
      <div class="wide">
      ${CUI.field({id:'activitySummary',label:'Summary',required:true,value:defaultSummary,attributes:'name="summary"'})}
      </div><div class="wide">${CUI.field({id:'activityDetail',label:'Detail',control:'textarea',attributes:'name="detail" rows="4"'})}</div>
      ${CUI.field({id:'activityOccurred',label:'Occurred at',type:'datetime-local',value:isoInput(new Date()),attributes:'name="occurred_at"'})}
      ${CUI.field({id:'activityDirection',label:'Direction',control:'select',options:['','outbound','inbound'].map(value=>({value,label:value?plainLabel(value):'Not recorded'})),attributes:'name="direction"'})}
      ${CUI.field({id:'activityOutcome',label:'Outcome',value:type==='npu'?'No answer':'',attributes:'name="outcome"'})}
      ${CUI.field({id:'activityDisposition',label:'Disposition',value:type==='npu'?'no_answer':'',attributes:'name="disposition"'})}
      ${CUI.field({id:'activityDuration',label:'Duration (seconds)',type:'number',attributes:'name="duration_seconds" min="0" step="1"'})}
      ${CUI.field({id:'activityNextAction',label:'Next action',attributes:'name="next_action"'})}
      ${CUI.field({id:'activityNextDue',label:'Next action due',type:'datetime-local',attributes:'name="next_action_due_at"'})}
      ${CUI.field({id:'activityMeetingAt',label:'Meeting at',type:'datetime-local',attributes:'name="meeting_at"'})}
      <div class="wide">${CUI.field({id:'activityMeetingUrl',label:'Meeting URL',type:'url',attributes:'name="meeting_url"'})}</div>
      <div class="wide">${CUI.field({id:'activityMeetingLocation',label:'Meeting location',attributes:'name="meeting_location"'})}</div>
    </div>`,
      onSubmit:async(form,controls)=>{
        const activityType=form.get('activity_type'),summary=type==='npu'?`NPU: ${form.get('summary')}`:form.get('summary');
        const result=asObject(await rpc(sb,'platform_add_prospect_activity_v76',{
          p_prospect:prospect.id||prospect.prospect_id,p_activity_type:activityType,
          p_summary:summary||defaultSummary,p_detail:form.get('detail')||null,
          p_occurred_at:nullableDateTime(form.get('occurred_at'))||new Date().toISOString(),
          p_idempotency_key:idempotencyKey()
        }));
        const activity=asObject(result.activity);
        if(activity.id){
          await rpc(sb,'platform_record_activity_detail_v86',{p_activity:activity.id,p_detail:{
            outcome:form.get('outcome')||null,disposition:form.get('disposition')||null,
            duration_seconds:nullableNumber(form.get('duration_seconds')),
            direction:form.get('direction')||null,channel:form.get('channel')||null,
            next_action:form.get('next_action')||null,next_action_due_at:nullableDateTime(form.get('next_action_due_at')),
            meeting_at:nullableDateTime(form.get('meeting_at')),meeting_url:form.get('meeting_url')||null,
            meeting_location:form.get('meeting_location')||null,attachments:[],created_source:'manual'
          }});
        }
        await refreshAfterProspectMutation(prospect.id||prospect.prospect_id,controls,context,'Activity saved.');
      }});
  }
  function taskModal(prospect,context) {
    const {CUI,sb}=context;
    modal({title:'Add task',submitLabel:'Create task',CUI,body:`
      ${CUI.field({id:'taskTitle',label:'Task',required:true,attributes:'name="title"'})}
      ${CUI.field({id:'taskDue',label:'Due at',type:'datetime-local',required:true,attributes:'name="due_at"'})}
      ${CUI.field({id:'taskConsultant',label:'Assigned consultant ID',attributes:'name="consultant"'})}`,
      onSubmit:async(form,controls)=>{
        await rpc(sb,'platform_create_prospect_task_v76',{p_prospect:prospect.id||prospect.prospect_id,p_title:form.get('title'),p_due_at:new Date(form.get('due_at')).toISOString(),p_assigned_consultant:form.get('consultant')||null,p_idempotency_key:idempotencyKey()});
        controls.close();context.close?.();await renderOnboarding(context);CUI.announce('Task created.');
      }});
  }
  function completeTaskModal(taskId,context) {
    const {CUI,sb}=context;
    modal({title:'Complete task',submitLabel:'Mark complete',CUI,body:CUI.field({id:'taskOutcome',label:'Outcome',control:'textarea',required:true,attributes:'name="outcome" rows="4"'}),
      onSubmit:async(form,controls)=>{
        await rpc(sb,'platform_complete_prospect_task_v76',{p_task:taskId,p_outcome:form.get('outcome'),p_idempotency_key:idempotencyKey()});
        controls.close();context.close?.();await renderOnboarding(context);CUI.announce('Task completed.');
      }});
  }
  function requestStageMove(prospect,toStage,context) {
    const current=prospectStage(prospect);
    if(toStage===current)return;
    if(['account_created','onboarding','activated'].includes(toStage)){
      context.CUI.announce('This stage is controlled by account conversion and onboarding evidence.',{assertive:true});
      return;
    }
    if(toStage==='lost')return lostStageModal(prospect,context);
    if(toStage==='client')return commercialTermsModal(prospect,context);
    return stageEvidenceModal(prospect,toStage,context);
  }
  function stageField(CUI,{id,label,type='text',control='input',required=true,options=[],hint='',wide=false,value=''}) {
    const field=CUI.field({id,label,type,control,required,options,value,attributes:`name="${id}"${control==='textarea'?' rows="3"':''}`,hint});
    return wide?`<div class="wide">${field}</div>`:field;
  }
  function stageEvidenceFieldSpecs(stage) {
    const now=new Date(Date.now()-new Date().getTimezoneOffset()*60000).toISOString().slice(0,16);
    const channel={id:'channel',label:'Channel',control:'select',options:['phone','sms','whatsapp','email','video','in_person'].map(value=>({value,label:plainLabel(value)}))};
    const specs={
      new_lead:[{id:'source',label:'Lead source'}],
      appt_set:[
        {id:'appointment_at',label:'Appointment at',type:'datetime-local'},
        {id:'appointment_owner',label:'Appointment owner'},
        {id:'next_action_at',label:'Next action at',type:'datetime-local'}
      ],
      call_back:[
        {id:'callback_at',label:'Callback at',type:'datetime-local'},
        {id:'assigned_person',label:'Assigned person'},
        {id:'context',label:'Reason / context',control:'textarea',wide:true}
      ],
      reschedule:[
        {id:'previous_meeting_reference',label:'Previous meeting reference'},
        {id:'new_meeting_at',label:'New meeting at',type:'datetime-local'},
        {id:'reschedule_reason',label:'Reschedule reason',control:'textarea',wide:true}
      ],
      meeting_sent:[
        {id:'meeting_at',label:'Confirmed meeting at',type:'datetime-local'},channel,
        {id:'attendees',label:'Attendees',hint:'Names or emails, comma separated.',wide:true},
        {id:'meeting_url',label:'Meeting URL',type:'url',required:false},
        {id:'physical_location',label:'Physical location',required:false}
      ],
      pending_decision:[
        {id:'qualification_summary',label:'Qualification summary',control:'textarea',wide:true},
        {id:'decision_maker',label:'Decision maker'},
        {id:'key_objection',label:'Key objection'},
        {id:'proposed_plan',label:'Proposed plan'},
        {id:'proposed_value_cents',label:'Proposed value (integer cents)',type:'number'},
        {id:'next_action_at',label:'Next action at',type:'datetime-local'},
        {id:'decision_at',label:'Decision date',type:'date',required:false},
        {id:'next_follow_up_at',label:'Next follow-up at',type:'datetime-local',required:false}
      ]
    };
    if(/^npu_[1-6]$/.test(stage))return[
      {id:'attempt_at',label:'Attempt at',type:'datetime-local',value:now},channel,
      {id:'next_attempt_at',label:'Next attempt at',type:'datetime-local',required:false},
      {id:'terminal_disposition',label:'Terminal disposition',required:false,hint:'Required only when no next attempt is scheduled.'}
    ];
    return specs[stage]||[];
  }
  function stageEvidenceModal(prospect,toStage,context) {
    const {CUI}=context,stageLabel=prospectStages.find(stage=>stage.key===toStage)?.label||plainLabel(toStage);
    const specs=stageEvidenceFieldSpecs(toStage);
    modal({title:`Move to ${stageLabel}`,submitLabel:'Review stage move',CUI,body:`
      <div class="platform-gate-summary"><b>Entry gate</b><ul>${asArray(stageGateDefinitions[toStage]).map(requirement=>`<li>${escapeHtml(requirement)}</li>`).join('')}</ul></div>
      <div class="platform-form-grid">${specs.map(spec=>stageField(CUI,spec)).join('')}</div>`,
      onSubmit:async(form,controls)=>{
        const evidence={};
        specs.forEach(spec=>{
          let value=String(form.get(spec.id)||'').trim();
          if(!value)return;
          if(spec.type==='datetime-local')value=new Date(value).toISOString();
          if(spec.type==='number')value=Number(value);
          if(spec.id==='attendees')value=value.split(',').map(item=>item.trim()).filter(Boolean).join(', ');
          evidence[spec.id]=value;
        });
        if(/^npu_[1-6]$/.test(toStage)&&!evidence.next_attempt_at&&!evidence.terminal_disposition)
          throw new Error('Schedule the next attempt or enter a terminal disposition.');
        if(toStage==='meeting_sent'&&!evidence.meeting_url&&!evidence.physical_location)
          throw new Error('Add a meeting URL or physical location.');
        if(toStage==='pending_decision'&&!evidence.decision_at&&!evidence.next_follow_up_at)
          throw new Error('Add a decision date or next follow-up.');
        controls.close();
        previewThenConfirm({
          title:`Confirm ${stageLabel}`,
          preview:{prospect:prospectCompany(prospect),from:prospectStage(prospect),to:toStage,entry_gate:stageGateDefinitions[toStage],evidence},
          CUI,onConfirm:async confirmControls=>{
            await performStageMove(prospect,toStage,{entryEvidence:evidence},context);
            confirmControls.close();
          }
        });
      }});
  }
  function lostStageModal(prospect,context) {
    const {CUI}=context;
    modal({title:'Mark prospect lost',submitLabel:'Preview lost transition',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'lostReason',label:'Reason',control:'select',required:true,options:lostReasons.map(value=>({value,label:plainLabel(value)})),attributes:'name="reason_code"'})}
      ${CUI.field({id:'lostCompetitor',label:'Competitor',attributes:'name="competitor"'})}
      ${CUI.field({id:'lostRecontact',label:'Recontact at',type:'date',attributes:'name="recontact_at"'})}
      <div class="wide">${CUI.field({id:'lostDetail',label:'Detail',control:'textarea',attributes:'name="reason_detail" rows="4"'})}</div>
    </div>`,onSubmit:async(form,controls)=>{
      const recontactPermission=Boolean(form.get('recontact_at'));
      const fields={reason_code:form.get('reason_code'),context:form.get('reason_detail')||form.get('competitor')||'No additional context',competitor:form.get('competitor')||null,recontact_permission:recontactPermission,recontact_at:form.get('recontact_at')||null};
      controls.close();previewThenConfirm({title:'Confirm lost transition',preview:{prospect:prospectCompany(prospect),from:prospectStage(prospect),to:'lost',...fields},CUI,onConfirm:async(confirmControls)=>{await performStageMove(prospect,'lost',{entryEvidence:fields},context);confirmControls.close()}});
    }});
  }
  function commercialTermsModal(prospect,context) {
    const {CUI}=context;
    modal({title:'Convert to client',submitLabel:'Preview conversion',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'termsProduct',label:'Product',required:true,attributes:'name="product_code"'})}
      ${CUI.field({id:'termsPlan',label:'Plan',required:true,attributes:'name="plan_code"'})}
      ${CUI.field({id:'termsSeats',label:'Seats',type:'number',required:true,attributes:'name="seats" min="1" step="1"'})}
      ${CUI.field({id:'termsCycle',label:'Billing cycle',control:'select',options:['quarterly','half_yearly','annual'].map(value=>({value,label:plainLabel(value)})),attributes:'name="billing_cycle"'})}
      ${CUI.field({id:'termsAmount',label:'Accepted amount (cents)',type:'number',required:true,attributes:'name="accepted_amount_cents" min="0" step="1"'})}
      ${CUI.field({id:'termsCurrency',label:'Currency',value:'SGD',required:true,attributes:'name="currency" maxlength="3"'})}
      ${CUI.field({id:'termsStatus',label:'Contract status',control:'select',options:[{value:'accepted',label:'Accepted'}],attributes:'name="contract_status"'})}
      ${CUI.field({id:'termsOwnerEmail',label:'Owner email',type:'email',required:true,attributes:'name="owner_email"'})}
      ${CUI.field({id:'termsOnboardingOwner',label:'Onboarding owner ID',required:true,attributes:'name="onboarding_owner"'})}
      ${CUI.field({id:'termsGoLive',label:'Target go-live',type:'date',required:true,attributes:'name="target_go_live"'})}
    </div>`,onSubmit:async(form,controls)=>{
      const terms={product_code:form.get('product_code'),plan_code:form.get('plan_code'),seats:Number(form.get('seats')),billing_cycle:form.get('billing_cycle'),accepted_value_cents:Number(form.get('accepted_amount_cents')),currency:String(form.get('currency')).toUpperCase(),contract_status:'accepted',owner_email:form.get('owner_email'),onboarding_owner_consultant_id:form.get('onboarding_owner'),target_go_live:form.get('target_go_live')};
      controls.close();previewThenConfirm({title:'Confirm commercial terms',preview:{prospect:prospectCompany(prospect),from:prospectStage(prospect),to:'client',entry_gate:stageGateDefinitions.client,commercial_terms:terms},CUI,onConfirm:async(confirmControls)=>{await performStageMove(prospect,'client',{entryEvidence:{explicit_confirmation:true},commercialTerms:terms},context);confirmControls.close()}});
    }});
  }
  async function performStageMove(prospect,toStage,options,context) {
    const {sb,CUI}=context;
    try{
      await rpc(sb,'platform_move_prospect_stage_v86',{
        p_prospect:prospect.id||prospect.prospect_id,p_to_stage:toStage,
        p_expected_version:prospectVersion(prospect),
        p_entry_evidence:options.entryEvidence||{},
        p_commercial_terms:options.commercialTerms||null,
        p_idempotency_key:idempotencyKey()
      });
      context.close?.();await renderOnboarding(context);CUI.announce(`Prospect moved to ${plainLabel(toStage)}.`);
    }catch(error){CUI.announce(error.message||'Stage move failed.',{assertive:true});throw error}
  }

  async function renderSectors(context) {
    const {main,CUI,sb}=context;
    main.innerHTML=loading(CUI,'Sector modules','Loading versioned sector entitlements…','packages');
    try{
      const [sectorPayload,rosterPayload]=await Promise.all([
        rpc(sb,'platform_list_sector_entitlements_v75'),
        rpc(sb,'platform_list_sector_firms_v89')
      ]);
      const payload=asObject(sectorPayload),profiles=asArray(payload.profiles);
      const assignments=asArray(payload.businesses);
      const assignmentsByBusiness=new Map(assignments.map(firm=>[firm.business_id,firm]));
      const roster=asArray(rosterPayload,['businesses','items','rows']);
      const businesses=roster.map(row=>{
        const businessId=row.business_id||row.id;
        return assignmentsByBusiness.get(businessId)||{
          business_id:businessId,
          business_name:row.business_name||row.name||'Unnamed firm',
          industry:row.industry||null,
          assignment_version:null,
          bundle_version_id:null,
          sector_key:null,
          bundle_version:null,
          override_version_id:null,
          effective_modules:asArray(row.enabled_modules)
        };
      });
      assignments.forEach(firm=>{
        if(!businesses.some(row=>row.business_id===firm.business_id))businesses.push(firm);
      });
      main.innerHTML=`${CUI.pageHeader({
        title:'Sector modules',subtitle:'Versioned module entitlements with explicit preview and confirmation before every change.',iconName:'packages',
        actions:`<button class="btn" type="button" id="platformNewBundle">${CUI.icon('add',{size:17})}<span>New bundle version</span></button>`
      })}
      <div class="platform-sector-list">${profiles.map(profile=>{
        const published=asObject(profile.published_version);
        return CUI.card({title:profile.label||profile.sector_key,description:`${profile.sector_key} · ${profile.active?'Active':'Inactive'}`,body:published.id?`
          <div class="platform-sector-card-head"><div><b>Published version ${escapeHtml(published.version)}</b><p class="muted small">${escapeHtml(published.label||'')}</p></div>${CUI.status('Published','ok')}</div>
          <div class="platform-module-list" aria-label="${escapeHtml(profile.label||profile.sector_key)} modules">${asArray(published.modules).filter(module=>module!=='inventory').map(module=>`<span class="chip on" title="${escapeHtml(module)}">${escapeHtml(moduleLabel(module))}</span>`).join('')}</div>
          <div class="platform-actions platform-sector-actions"><button type="button" class="btn ghost sm" data-edit-sector="${escapeHtml(profile.sector_key)}">${CUI.icon('edit',{size:16})}<span>Edit modules</span></button></div>`
          :`${CUI.emptyState({iconName:'packages',title:'No published version',body:'Choose the standard modules and publish the first bundle.'})}<div class="platform-actions platform-sector-actions"><button type="button" class="btn ghost sm" data-edit-sector="${escapeHtml(profile.sector_key)}">${CUI.icon('add',{size:16})}<span>Choose modules</span></button></div>`});
      }).join('')||CUI.emptyState({iconName:'packages',title:'No sector profiles',body:'The platform returned no active sector profiles.'})}</div>
      <section class="card" style="margin-top:16px"><div class="platform-list-row"><div><h2 style="font-size:16px">Firm entitlements</h2><p class="muted small">${assignments.length} of ${businesses.length} firm${businesses.length===1?'':'s'} assigned.</p></div></div>
        ${businesses.length?CUI.table({caption:'Firm sector entitlements',headers:['Firm','Sector','Bundle','Assignment','Effective modules','Actions'],rows:businesses.map(firm=>[
          `<b>${escapeHtml(firm.business_name)}</b>`,
          firm.sector_key?escapeHtml(firm.sector_key):CUI.status('Unassigned','off'),
          firm.bundle_version?`v${escapeHtml(firm.bundle_version)}`:'—',
          firm.assignment_version?`v${escapeHtml(firm.assignment_version)}`:'—',
          firm.assignment_version?escapeHtml(asArray(firm.effective_modules).filter(module=>module!=='inventory').map(moduleLabel).join(', ')):'—',
          `<div class="platform-actions"><button type="button" class="btn ghost sm" data-assign-firm="${escapeHtml(firm.business_id)}">${firm.assignment_version?'Reassign':'Assign'}</button>${firm.assignment_version?`<button type="button" class="btn ghost sm" data-override-firm="${escapeHtml(firm.business_id)}">Override</button>`:''}</div>`
        ])}):CUI.emptyState({iconName:'branch',title:'No firms',body:'No firms are available for sector assignment.'})}
      </section>`;
      main.querySelector('#platformNewBundle').onclick=()=>sectorBundleModal({profiles,context});
      main.querySelectorAll('[data-edit-sector]').forEach(button=>button.onclick=()=>sectorBundleModal({
        profiles,context,profile:profiles.find(item=>item.sector_key===button.dataset.editSector)
      }));
      main.querySelectorAll('[data-assign-firm]').forEach(button=>button.onclick=()=>assignSectorModal(businesses.find(item=>item.business_id===button.dataset.assignFirm),profiles,context));
      main.querySelectorAll('[data-override-firm]').forEach(button=>button.onclick=()=>sectorOverrideModal(businesses.find(item=>item.business_id===button.dataset.overrideFirm),context));
      CUI.focusRoute(main);
    }catch(error){showError(main,error,CUI,'Sector modules')}
  }
  function modulePickerHtml(selectedModules=[]) {
    const selected=new Set(asArray(selectedModules).filter(module=>module!=='inventory'));
    const groups=[...new Set(sectorModuleCatalog.map(module=>module.group))];
    return `<fieldset class="platform-module-picker"><legend>Choose the standard modules</legend>
      <p class="muted small">These modules become the sector template. Existing published versions remain unchanged.</p>
      ${groups.map(group=>`<section class="platform-module-group" aria-labelledby="module-group-${group.toLowerCase().replace(/\W+/g,'-')}">
        <h2 id="module-group-${group.toLowerCase().replace(/\W+/g,'-')}">${escapeHtml(group)}</h2>
        <div class="platform-module-options">${sectorModuleCatalog.filter(module=>module.group===group).map(module=>`
          <label class="platform-module-option">
            <input type="checkbox" name="modules" value="${escapeHtml(module.key)}"${selected.has(module.key)?' checked':''}>
            <span><b>${escapeHtml(module.label)}</b><small>${escapeHtml(module.key)}</small></span>
          </label>`).join('')}</div>
      </section>`).join('')}
      <div class="platform-module-selection" aria-live="polite"><b data-module-count>${selected.size} selected</b><span data-module-summary>${selected.size?escapeHtml([...selected].map(moduleLabel).join(', ')):'Choose at least one module.'}</span></div>
    </fieldset>`;
  }
  function sectorBundleReviewModal({profile,args,preview,context}) {
    const {CUI,sb}=context;
    const withoutInventory=value=>asArray(value).filter(module=>module!=='inventory');
    const current=withoutInventory(profile?.published_version?.modules);
    const requested=withoutInventory(asArray(preview?.requested_modules).length?preview.requested_modules:args.p_modules);
    const resolved=withoutInventory(asArray(preview?.resolved_modules).length?preview.resolved_modules:requested);
    const added=resolved.filter(module=>!current.includes(module));
    const removed=current.filter(module=>!resolved.includes(module));
    const version=preview?.next_version??preview?.version??'next';
    let createdBundleId=null;
    modal({title:`Review ${profile?.label||args.p_sector_key} bundle`,submitLabel:'Create and publish',CUI,body:`
      <div class="platform-bundle-review">
        <div class="platform-route-note">${CUI.icon('info',{size:19})}<div><b>New immutable version ${escapeHtml(version)}</b><p class="small">Publishing changes the default module template for future firm assignments. Previous versions stay available for audit.</p></div></div>
        <dl class="platform-context-list">
          <div><dt>Sector</dt><dd>${escapeHtml(profile?.label||plainLabel(args.p_sector_key))}</dd></div>
          <div><dt>Version label</dt><dd>${escapeHtml(args.p_label)}</dd></div>
          <div><dt>Modules after dependencies</dt><dd>${escapeHtml(resolved.length)}</dd></div>
        </dl>
        <section><h2>Included modules</h2><div class="platform-module-list">${resolved.map(module=>`<span class="chip on" title="${escapeHtml(module)}">${escapeHtml(moduleLabel(module))}</span>`).join('')}</div></section>
        <div class="platform-bundle-diff">
          <section><h2>Added</h2>${added.length?`<ul>${added.map(module=>`<li>${escapeHtml(moduleLabel(module))}</li>`).join('')}</ul>`:'<p class="muted small">No modules added.</p>'}</section>
          <section><h2>Removed</h2>${removed.length?`<ul>${removed.map(module=>`<li>${escapeHtml(moduleLabel(module))}</li>`).join('')}</ul>`:'<p class="muted small">No modules removed.</p>'}</section>
        </div>
        ${resolved.length!==requested.length?`<p class="muted small">Nestly added ${escapeHtml(resolved.length-requested.length)} required dependenc${resolved.length-requested.length===1?'y':'ies'} automatically.</p>`:''}
        <label class="platform-review-confirm"><input type="checkbox" name="reviewed" value="yes"><span>I reviewed the module list and understand this publishes a new immutable version.</span></label>
      </div>`,onSubmit:async(form,controls)=>{
        if(form.get('reviewed')!=='yes')throw new Error('Review the module list and tick the confirmation before publishing.');
        if(!createdBundleId){
          const created=await rpc(sb,'platform_create_sector_bundle_v75',{...args,p_dry_run:false});
          createdBundleId=created.bundle_version_id;
        }
        await rpc(sb,'platform_publish_sector_bundle_v75',{p_bundle_version:createdBundleId,p_dry_run:true});
        await rpc(sb,'platform_publish_sector_bundle_v75',{p_bundle_version:createdBundleId,p_dry_run:false});
        controls.close();await renderSectors(context);CUI.announce(`${profile?.label||plainLabel(args.p_sector_key)} module bundle published.`);
      }});
  }
  function sectorBundleModal({profiles,context,profile=null}) {
    const {CUI,sb}=context;
    const initial=profile||profiles[0]||{},published=asObject(initial.published_version);
    const defaultLabel=`${initial.label||plainLabel(initial.sector_key)} · ${new Date().toLocaleDateString('en-SG',{year:'numeric',month:'short',day:'2-digit'})}`;
    const overlay=modal({title:published.id?`Edit ${initial.label||initial.sector_key} modules`:'Create sector bundle version',submitLabel:'Review version',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'bundleSector',label:'Sector',control:'select',options:profiles.map(item=>({value:item.sector_key,label:item.label||item.sector_key,selected:item.sector_key===initial.sector_key})),attributes:'name="sector_key"'})}
      ${CUI.field({id:'bundleLabel',label:'Version label',required:true,value:defaultLabel,attributes:'name="label"'})}
      <div class="wide" data-module-picker-host>${modulePickerHtml(asArray(published.modules))}</div>
    </div>`,onSubmit:async(form,controls)=>{
      const selected=form.getAll('modules').map(String);
      if(!selected.length)throw new Error('Choose at least one module for this sector.');
      const selectedProfile=profiles.find(item=>item.sector_key===form.get('sector_key'))||initial;
      const args={p_sector_key:form.get('sector_key'),p_label:String(form.get('label')).trim(),p_modules:selected,p_dry_run:true};
      const preview=await rpc(sb,'platform_create_sector_bundle_v75',args);
      controls.close();sectorBundleReviewModal({profile:selectedProfile,args,preview,context});
    }});
    const sectorSelect=overlay.querySelector('#bundleSector'),pickerHost=overlay.querySelector('[data-module-picker-host]');
    const wirePicker=()=>{
      const checkboxes=[...pickerHost.querySelectorAll('input[name="modules"]')];
      const selected=checkboxes.filter(input=>input.checked).map(input=>input.value);
      pickerHost.querySelector('[data-module-count]').textContent=`${selected.length} selected`;
      pickerHost.querySelector('[data-module-summary]').textContent=selected.length?selected.map(moduleLabel).join(', '):'Choose at least one module.';
    };
    pickerHost.addEventListener('change',wirePicker);
    sectorSelect.onchange=()=>{
      const next=profiles.find(item=>item.sector_key===sectorSelect.value);
      pickerHost.innerHTML=modulePickerHtml(asArray(next?.published_version?.modules));
      overlay.querySelector('#bundleLabel').value=`${next?.label||plainLabel(sectorSelect.value)} · ${new Date().toLocaleDateString('en-SG',{year:'numeric',month:'short',day:'2-digit'})}`;
      wirePicker();
    };
  }
  function assignSectorModal(firm,profiles,context) {
    const {CUI,sb}=context;
    const versions=profiles.map(profile=>profile.published_version).filter(version=>version?.id);
    modal({title:`Assign sector to ${firm?.business_name||'firm'}`,submitLabel:'Preview assignment',CUI,body:CUI.field({id:'assignBundle',label:'Published bundle',control:'select',options:versions.map(version=>({value:version.id,label:`${version.label} · v${version.version}`})),attributes:'name="bundle_version"'}),
      onSubmit:async(form,controls)=>{
        const args={p_business:firm.business_id,p_bundle_version:form.get('bundle_version'),p_expected_version:firm.assignment_version??null,p_dry_run:true};
        const preview=await rpc(sb,'platform_assign_business_sector_v75',args);controls.close();
        previewThenConfirm({title:'Confirm firm sector assignment',preview,CUI,onConfirm:async(confirmControls)=>{
          await rpc(sb,'platform_assign_business_sector_v75',{...args,p_dry_run:false});confirmControls.close();await renderSectors(context);CUI.announce('Firm sector assigned.');
        }});
      }});
  }
  function sectorOverrideModal(firm,context) {
    const {CUI,sb}=context;
    modal({title:`Override modules for ${firm.business_name}`,submitLabel:'Preview override',CUI,body:`
      ${CUI.field({id:'overrideAdd',label:'Add modules',hint:'Comma-separated module keys.',attributes:'name="add_modules"'})}
      ${CUI.field({id:'overrideRemove',label:'Remove modules',hint:'Comma-separated module keys.',attributes:'name="remove_modules"'})}
      ${CUI.field({id:'overrideReason',label:'Reason',control:'textarea',required:true,attributes:'name="reason" rows="4"'})}`,
      onSubmit:async(form,controls)=>{
        const values=name=>String(form.get(name)||'').split(',').map(value=>value.trim()).filter(Boolean);
        const args={p_business:firm.business_id,p_add_modules:values('add_modules'),p_remove_modules:values('remove_modules'),p_reason:form.get('reason'),p_expected_version:firm.assignment_version,p_dry_run:true};
        const preview=await rpc(sb,'platform_set_business_sector_override_v75',args);controls.close();
        previewThenConfirm({title:'Confirm firm module override',preview,CUI,onConfirm:async(confirmControls)=>{
          await rpc(sb,'platform_set_business_sector_override_v75',{...args,p_dry_run:false});confirmControls.close();await renderSectors(context);CUI.announce('Firm module override applied.');
        }});
      }});
  }

  async function renderBilling(context) {
    const {main,CUI,sb}=context;
    main.innerHTML=loading(CUI,'Billing','Loading platform billing truth…','reports');
    try{
      const [billingPayload,catalogPayload,reconciliationPayload]=await Promise.all([
        rpc(sb,'platform_get_billing_v89',{p_business:null,p_limit:250}),
        rpc(sb,'get_billing_price_catalog_v77',{p_currency:null}),
        rpc(sb,'platform_get_billing_reconciliation_v89',{p_run:null,p_limit:50})
      ]);
      const rows=asArray(billingPayload);
      const catalog=asArray(catalogPayload);
      const reconciliationRuns=asArray(reconciliationPayload?.runs);
      const latestReconciliation=reconciliationRuns[0]?.id
        ?asObject(await rpc(sb,'platform_get_billing_reconciliation_v89',{p_run:reconciliationRuns[0].id,p_limit:50}))
        :asObject(reconciliationPayload);
      const reconciliationItems=asArray(latestReconciliation.items);
      const exceptions=rows.filter(row=>row.status==='past_due'||row.payment_status==='past_due'||Number(row.failed_event_count||0)>0);
      const totals=rows.reduce((value,row)=>({
        total:value.total+Number(row.period_total_cents||0),overdue:value.overdue+(row.status==='past_due'?1:0),
        paid:value.paid+(row.last_paid_at?1:0),failed:value.failed+Number(row.failed_event_count||0)
      }),{total:0,overdue:0,paid:0,failed:0});
      main.innerHTML=`${CUI.pageHeader({title:'Billing',subtitle:'Provider-backed subscription, GST and payment status. Amounts are integer cents from the billing ledger.',iconName:'reports',
        actions:`<button type="button" class="btn" id="platformNewBillingPrice">${CUI.icon('add',{size:17})}<span>New price version</span></button>`})}
        <section class="platform-kpis" aria-label="Billing summary">${[
          ['Period total incl. GST',currency(totals.total),'reports'],['Paid firms',totals.paid,'check'],['Overdue firms',totals.overdue,'info'],['Failed events',totals.failed,'retention']
        ].map(([label,value,icon])=>`<article class="card platform-kpi"><div class="platform-kpi-label">${CUI.icon(icon,{size:17})}<span>${escapeHtml(label)}</span></div><div class="platform-kpi-value">${escapeHtml(value)}</div></article>`).join('')}</section>
        ${CUI.card({title:'Stripe price catalogue',description:'Active versions drive checkout and cadence changes. Prior versions remain visible as history.',body:catalog.length?CUI.table({caption:'Stripe price catalogue',headers:['Currency','Cadence','Base','Per seat','Included','Tax','Status','Effective'],rows:catalog.map(row=>[
          escapeHtml(row.currency),escapeHtml(plainLabel(row.cadence)),currency(row.base_amount_cents,row.currency),
          currency(row.per_seat_amount_cents,row.currency),String(row.included_seats),
          escapeHtml(plainLabel(row.tax_behavior)),CUI.status(row.active?'Active':'Retired',row.active?'ok':'off'),
          escapeHtml(dateTime(row.effective_from))
        ])}):CUI.emptyState({iconName:'reports',title:'No Stripe prices configured',body:'Create one active version for each offered billing cadence before opening checkout.'})})}
        <div class="platform-detail-grid">
          ${CUI.card({title:'Billing exception queue',description:exceptions.length?`${exceptions.length} firm${exceptions.length===1?'':'s'} require payment follow-up.`:'No overdue or failed firm billing records.',body:exceptions.length?exceptions.map(row=>`<div class="platform-action-item"><div><button type="button" class="platform-link-button" data-billing-firm="${escapeHtml(row.business_id)}"><b>${escapeHtml(row.business_name)}</b></button><p class="muted small">${escapeHtml(plainLabel(row.payment_status||row.status))} · next payment ${escapeHtml(dateTime(row.next_payment_at))}</p></div>${CUI.status(`${Number(row.failed_event_count||0)} failed`,'no')}</div>`).join(''):'<p class="muted small">Payments and provider status are currently reconciled.</p>'})}
          ${CUI.card({title:'Latest provider reconciliation',description:reconciliationRuns[0]?`${dateTime(reconciliationRuns[0].started_at)} · ${plainLabel(reconciliationRuns[0].run_mode)}`:'No reconciliation run was returned.',body:reconciliationItems.length?reconciliationItems.map(item=>`<div class="platform-action-item"><div><b>${escapeHtml(plainLabel(item.object_type))}</b><p class="muted small">${escapeHtml(item.provider_object_id||'Provider object')} · ${escapeHtml(dateTime(item.created_at))}</p></div>${CUI.status(plainLabel(item.result),item.result==='matched'?'ok':'no')}</div>`).join(''):reconciliationRuns[0]?'<p class="muted small">The latest returned run has no exception items.</p>':'<p class="muted small">Reconciliation history will appear after the first automated run.</p>'})}
        </div>
        ${CUI.card({title:'Reconciliation history',description:'Automatic and manual provider comparisons. Open exception records above for the affected firm.',body:reconciliationRuns.length?CUI.table({caption:'Billing reconciliation history',headers:['Started','Mode','Status','Finished','Summary'],rows:reconciliationRuns.map(run=>[
          escapeHtml(dateTime(run.started_at)),escapeHtml(plainLabel(run.run_mode)),CUI.status(plainLabel(run.status),run.status==='completed'?'ok':run.status==='failed'?'no':'off'),escapeHtml(dateTime(run.finished_at)),escapeHtml(JSON.stringify(run.summary||{}))
        ])}):'<p class="muted small">No reconciliation runs.</p>'})}
        ${CUI.card({title:'Firm billing',description:rows.length?`${rows.length} subscriptions. Open a firm for invoices, attempts and available commands.`:'No subscriptions returned.',body:rows.length?CUI.table({caption:'Platform billing',headers:['Firm','Subscription','Payment','Cadence','Last paid','Next payment','Subtotal','GST','Total','Attempts'],rows:rows.map(row=>[
          `<button type="button" class="customer-link" data-billing-firm="${escapeHtml(row.business_id)}">${escapeHtml(row.business_name)}</button>`,
          CUI.status(row.status||'—',statusTone(row.status)),CUI.status(row.payment_status||'—',row.payment_status==='paid'?'ok':row.payment_status==='past_due'?'no':'off'),escapeHtml(plainLabel(row.cadence)),escapeHtml(dateTime(row.last_paid_at)),escapeHtml(dateTime(row.next_payment_at)),
          currency(row.period_subtotal_cents,row.currency),currency(row.period_tax_cents,row.currency),`<span class="platform-money">${currency(row.period_total_cents,row.currency)}</span>`,String(row.failed_event_count||0)
        ])}):CUI.emptyState({iconName:'reports',title:'No billing records',body:'The billing reader returned no subscriptions.'})})}`;
      main.querySelector('#platformNewBillingPrice').onclick=()=>billingPriceModal(context);
      main.querySelectorAll('[data-billing-firm]').forEach(button=>button.onclick=()=>openBillingDetail(button.dataset.billingFirm,context));
      CUI.focusRoute(main);
    }catch(error){showError(main,error,CUI,'Billing')}
  }
  function billingPriceModal(context) {
    const {CUI,sb}=context;
    const defaultEffective=new Date(Date.now()-new Date().getTimezoneOffset()*60000).toISOString().slice(0,16);
    modal({title:'New Stripe price version',submitLabel:'Preview price',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'billingPriceCurrency',label:'Currency',value:'SGD',required:true,attributes:'name="currency" maxlength="3"'})}
      ${CUI.field({id:'billingPriceCadence',label:'Cadence',control:'select',options:['quarterly','half_yearly','annual'].map(value=>({value,label:plainLabel(value)})),attributes:'name="cadence"'})}
      ${CUI.field({id:'billingBasePriceId',label:'Stripe base price ID',required:true,attributes:'name="base_price_id" placeholder="price_..."'})}
      ${CUI.field({id:'billingSeatPriceId',label:'Stripe seat price ID',required:true,attributes:'name="seat_price_id" placeholder="price_..."'})}
      ${CUI.field({id:'billingBaseAmount',label:'Base amount (cents)',type:'number',required:true,attributes:'name="base_amount_cents" min="0" step="1"'})}
      ${CUI.field({id:'billingSeatAmount',label:'Per-seat amount (cents)',type:'number',required:true,attributes:'name="seat_amount_cents" min="0" step="1"'})}
      ${CUI.field({id:'billingIncludedSeats',label:'Included seats',type:'number',value:'1',required:true,attributes:'name="included_seats" min="0" step="1"'})}
      ${CUI.field({id:'billingTaxBehavior',label:'Tax behaviour',control:'select',options:['exclusive','inclusive','unspecified'].map(value=>({value,label:plainLabel(value)})),attributes:'name="tax_behavior"'})}
      ${CUI.field({id:'billingEffectiveFrom',label:'Effective from',type:'datetime-local',value:defaultEffective,required:true,attributes:'name="effective_from"'})}
      <div class="wide">${CUI.field({id:'billingPriceReason',label:'Reason',control:'textarea',required:true,attributes:'name="reason" rows="3"'})}</div>
    </div>`,onSubmit:async(form,controls)=>{
      const proposal={
        p_currency:String(form.get('currency')).toUpperCase(),
        p_cadence:form.get('cadence'),
        p_provider_base_price_id:form.get('base_price_id'),
        p_provider_seat_price_id:form.get('seat_price_id'),
        p_base_amount_cents:Number(form.get('base_amount_cents')),
        p_per_seat_amount_cents:Number(form.get('seat_amount_cents')),
        p_included_seats:Number(form.get('included_seats')),
        p_tax_behavior:form.get('tax_behavior'),
        p_effective_from:new Date(form.get('effective_from')).toISOString()
      };
      const preview=await rpc(sb,'preview_billing_price_catalog_v77',proposal);
      const reason=form.get('reason');
      controls.close();
      previewThenConfirm({title:'Confirm Stripe price version',preview,CUI,onConfirm:async confirmControls=>{
        await rpc(sb,'confirm_billing_price_catalog_v77',{
          ...proposal,p_confirmation_hash:preview.confirmation_hash,p_reason:reason
        });
        confirmControls.close();await renderBilling(context);CUI.announce('Stripe price version activated.');
      }});
    }});
  }
  async function openBillingDetail(businessId,context) {
    const {CUI,sb}=context;
    const overlay=document.createElement('div');overlay.className='platform-drawer';overlay.tabIndex=-1;
    overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');overlay.setAttribute('aria-labelledby','billingDetailTitle');
    overlay.innerHTML=`<section class="platform-drawer-panel"><div class="platform-drawer-head"><div><h1 id="billingDetailTitle" style="font-size:1.45rem">Billing detail</h1><p class="muted small">Provider-backed subscription record</p></div><button class="btn ghost sm platform-drawer-close" type="button" aria-label="Close detail">${CUI.icon('close',{size:18})}</button></div><div data-detail>${CUI.loadingState({title:'Billing detail',body:'Loading invoices and payment attempts…',iconName:'reports'})}</div></section>`;
    document.body.appendChild(overlay);let deactivate;const close=()=>closeOverlay(overlay,deactivate);
    overlay.querySelector('.platform-drawer-close').onclick=close;deactivate=CUI.activateDialog(overlay,{onClose:close,initialFocus:'.platform-drawer-close'});
    try{
      const detail=asObject(await rpc(sb,'get_business_billing_v77',{p_business:businessId}));
      const commands=billingCommands(detail);
      overlay.querySelector('[data-detail]').innerHTML=`<div class="platform-actions" style="margin-bottom:14px">${commands.map(command=>`<button type="button" class="btn ${command.danger?'danger':'ghost'} sm" data-billing-command="${command.type}" data-cadence="${command.cadence||''}">${escapeHtml(command.label)}</button>`).join('')}</div>
        <div class="platform-detail-grid">${CUI.card({title:'Subscription',body:detailObjectHtml({status:detail.status,cadence:detail.cadence,billable_seats:detail.billable_seats,last_paid_at:detail.last_paid_at,next_payment_at:detail.next_payment_at,cancel_at_period_end:detail.cancel_at_period_end})})}${CUI.card({title:'Current period',body:detailObjectHtml({subtotal_ex_gst_cents:detail.period_subtotal_cents,gst_cents:detail.period_tax_cents,total_including_gst_cents:detail.period_total_cents,currency:detail.currency})})}</div>
        <section class="card platform-detail-section"><h2>Invoices</h2>${asArray(detail.invoices).map(invoice=>`<div class="platform-action-item"><div><b>${escapeHtml(invoice.number||invoice.provider_invoice_id)}</b><p class="muted small">${escapeHtml(invoice.status)} · ${currency(invoice.total_cents,invoice.currency)} incl. GST</p></div><span>${invoice.paid_normalized?CUI.status('Paid','ok'):CUI.status('Outstanding','no')}</span></div>`).join('')||'<p class="muted small">No invoices.</p>'}</section>
        <section class="card platform-detail-section"><h2>Payment attempts</h2>${asArray(detail.payment_attempts).map(attempt=>`<div class="platform-action-item"><div><b>${escapeHtml(plainLabel(attempt.attempt_state))}</b><p class="muted small">${currency(attempt.amount_cents,detail.currency)} · ${escapeHtml(attempt.failure_code||'No failure')}</p></div><span class="muted small">${escapeHtml(dateTime(attempt.occurred_at))}</span></div>`).join('')||'<p class="muted small">No payment attempts.</p>'}</section>
        <section class="card platform-detail-section"><h2>Adjustments</h2>${asArray(detail.adjustments).map(adjustment=>`<div class="platform-action-item"><div><b>${escapeHtml(plainLabel(adjustment.adjustment_type))}</b><p class="muted small">${currency(adjustment.total_cents,adjustment.currency||detail.currency)} incl. GST · ${escapeHtml(adjustment.reason||'No reason recorded')}</p></div><span class="muted small">${escapeHtml(dateTime(adjustment.occurred_at))}</span></div>`).join('')||'<p class="muted small">No adjustments.</p>'}</section>
        <section class="card platform-detail-section"><h2>Commands</h2>${asArray(detail.commands).map(command=>detailObjectHtml(command)).join('')||'<p class="muted small">No billing commands.</p>'}</section>`;
      overlay.querySelectorAll('[data-billing-command]').forEach(button=>button.onclick=()=>requestBillingCommand(businessId,button.dataset.billingCommand,button.dataset.cadence||null,{...context,close}));
    }catch(error){overlay.querySelector('[data-detail]').innerHTML=error.platformUpdateRequired?systemUpdateRequired(CUI,'Billing detail'):CUI.errorState({title:'Billing detail unavailable',message:error.message})}
  }
  function billingCommands(detail) {
    const commands=[];
    const hasCustomer=!!detail.provider?.customer_id,hasSubscription=!!detail.provider?.subscription_id;
    if(!hasSubscription)commands.push({type:'create_checkout',cadence:detail.cadence||'annual',label:'Create checkout'});
    if(hasCustomer)commands.push({type:'create_portal',label:'Open billing portal'});
    if(hasSubscription&&!['canceled','cancelled'].includes(detail.status))commands.push({type:'change_cadence',cadence:detail.cadence==='annual'?'quarterly':'annual',label:'Change cadence'});
    if(hasSubscription&&detail.cancel_at_period_end)commands.push({type:'resume',label:'Resume'});
    else if(hasSubscription&&['active','trialing','past_due'].includes(detail.status))commands.push({type:'cancel_at_period_end',label:'Cancel at period end',danger:true});
    return commands;
  }
  function requestBillingCommand(businessId,type,cadence,context) {
    const {CUI,sb}=context;
    const label=plainLabel(type);
    previewThenConfirm({title:`Confirm ${label}`,preview:{business_id:businessId,command_type:type,cadence},CUI,onConfirm:async(controls)=>{
      const requested=await rpc(sb,'request_billing_command_v77',{p_business:businessId,p_command_type:type,p_cadence:cadence,p_idempotency_key:idempotencyKey()});
      let result=requested;
      if(['pending','processing','uncertain'].includes(requested?.status)){
        if(!sb.functions?.invoke)throw new Error('The billing command executor is unavailable.');
        const executed=await sb.functions.invoke('stripe-billing-command',{body:{command_id:requested.command_id}});
        if(executed?.error)throw executed.error;
        result=executed?.data||requested;
        if(result?.status==='uncertain'){
          const recovered=await sb.functions.invoke('stripe-billing-command',{body:{command_id:requested.command_id}});
          if(recovered?.error)throw recovered.error;
          result=recovered?.data||result;
        }
      }
      controls.close();context.close?.();
      if(result?.redirect_url&&['create_checkout','create_portal'].includes(type)){
        if(globalObject.location?.assign)globalObject.location.assign(result.redirect_url);
        else globalObject.open(result.redirect_url,'_blank','noopener');
        return;
      }
      await renderBilling(context);CUI.announce(`Billing command ${result?.status||'queued'}.`);
    }});
  }

  async function renderCommission(context) {
    const {main,CUI,sb}=context;
    main.innerHTML=loading(CUI,'Commission payable','Loading consultant commission truth…','staff');
    try{
      const [dashboard,policiesPayload,directoryPayload]=await Promise.all([
        rpc(sb,'get_consultant_commission_dashboard_v78',{p_consultant:null,p_limit:100}),
        rpc(sb,'get_consultant_commission_policies_v78'),
        rpc(sb,'platform_list_commission_consultants_v89')
      ]);
      const view=asObject(dashboard),totals=asObject(view.totals);
      const directory=asArray(directoryPayload,['consultants','items']);
      const consultants=asArray(view,['consultants','roster']).map(row=>({
        ...directory.find(item=>(item.id||item.consultant_id)===(row.consultant_id||row.id)),
        ...row
      })),accruals=asArray(view,['accruals','commission_accruals']);
      const batches=asArray(view,['payout_batches','batches']),lines=asArray(view,['payout_lines','lines']);
      const policies=asArray(policiesPayload,['policies','items']);
      const consultantTotal=field=>consultants.reduce((value,row)=>value+Number(row[field]||0),0);
      const sum=status=>Number(totals[`${status}_cents`]??consultantTotal(`${status}_cents`)
        ??accruals.filter(row=>row.status===status).reduce((value,row)=>value+Number(row.amount_cents||row.commission_cents||0),0));
      main.innerHTML=`${CUI.pageHeader({
        title:'Commission payable',subtitle:'Consultant commission is calculated on net-of-GST subscription amounts. All stored and entered amounts are integer cents.',iconName:'staff',
        actions:`<button type="button" class="btn ghost" id="platformNewConsultant">New consultant</button><button type="button" class="btn ghost" id="platformAttributeConsultant">Attribute consultant</button><button type="button" class="btn ghost" id="platformNewPolicy">New policy</button><button type="button" class="btn" id="platformNewPayout">New payout batch</button>`
      })}
      <section class="platform-kpis" aria-label="Commission totals">${[
        ['Payable net of GST',currency(sum('payable')),'reports'],['Approved',currency(sum('approved')),'check'],
        ['Paid',currency(sum('paid')),'staff'],['Forfeited',currency(sum('forfeited')),'info']
      ].map(([label,value,icon])=>`<article class="card platform-kpi"><div class="platform-kpi-label">${CUI.icon(icon,{size:17})}<span>${escapeHtml(label)}</span></div><div class="platform-kpi-value">${escapeHtml(value)}</div></article>`).join('')}</section>
      <div class="platform-detail-grid">
        ${CUI.card({title:'Consultant roster',body:consultants.length?CUI.table({caption:'Consultant commission roster',headers:['Consultant','Role','Payable','Approved','Paid','Actions'],rows:consultants.map(row=>[
          `<b>${escapeHtml(row.display_name||row.consultant_name||row.name||row.consultant_id)}</b>`,escapeHtml(plainLabel(row.tier||row.role)),currency(row.payable_cents),currency(row.approved_cents),currency(row.paid_cents),
          row.active!==false
            ?`<div class="platform-actions"><button type="button" class="btn ghost sm" data-edit-consultant="${escapeHtml(row.consultant_id||row.id)}">Edit</button><button type="button" class="btn danger sm" data-forfeit-consultant="${escapeHtml(row.consultant_id||row.id)}">Record departure</button></div>`
            :CUI.status('Departed','off')
        ])}):CUI.emptyState({iconName:'staff',title:'No consultants',body:'No consultant commission records were returned.'})})}
        ${CUI.card({title:'Policy history',description:'Base, service-anniversary bonus, and renewal rates are editable in basis points.',body:policies.length?policies.map(policy=>`<div class="platform-action-item"><div><b>${escapeHtml(plainLabel(policy.tier||policy.role))}</b><p class="muted small">Year-one base ${Number(policy.first_year_bps||0)/100}% · 12-month service bonus ${Number(policy.anniversary_bonus_bps||0)/100}% · Renewal ${Number(policy.renewal_bps||0)/100}%</p></div><span class="muted small">${escapeHtml(dateTime(policy.effective_from))}</span></div>`).join(''):CUI.emptyState({iconName:'reports',title:'No policy history',body:'No consultant commission policies were returned.'})})}
      </div>
      <section class="card platform-detail-section"><h2>Accruals</h2>${accruals.length?CUI.table({caption:'Consultant commission accruals',headers:['Consultant','Type','Status','Net-of-GST basis','Commission','Actions'],rows:accruals.map(row=>[
        escapeHtml(row.consultant_name||consultants.find(item=>item.consultant_id===row.consultant_id)?.display_name||row.consultant_id),escapeHtml(plainLabel(row.commission_phase||row.commission_type||row.kind)),CUI.status(row.status||'accrued',row.status==='paid'?'ok':row.status==='forfeited'?'off':'new'),
        currency(row.net_of_gst_cents||row.basis_cents,row.currency),`<span class="platform-money">${currency(row.amount_cents||row.commission_cents,row.currency)}</span>`,
        row.status==='accrued'?`<button type="button" class="btn ghost sm" data-approve-accrual="${escapeHtml(row.accrual_id||row.id)}">Approve</button>`:''
      ])}):'<p class="muted small">No accruals.</p>'}</section>
      <section class="card platform-detail-section"><h2>Payout workflow</h2>${batches.map(batch=>`<div class="platform-action-item"><div><b>Batch ${escapeHtml(batch.batch_id||batch.id)}</b><p class="muted small">${escapeHtml(batch.status||'draft')} · ${escapeHtml(batch.currency||'SGD')}</p></div><div class="platform-actions">${batch.status==='draft'?`<button class="btn ghost sm" data-add-payout-line="${escapeHtml(batch.batch_id||batch.id)}">Add line</button><button class="btn sm" data-approve-payout="${escapeHtml(batch.batch_id||batch.id)}">Approve batch</button>`:''}</div></div>`).join('')||'<p class="muted small">No payout batches.</p>'}
        ${lines.filter(line=>Number(line.remaining_cents??line.amount_cents)>0&&(line.recordable===true||(!('recordable' in line)&&!['paid','void'].includes(line.batch_status||line.status)))).map(line=>`<div class="platform-action-item"><div><b>Line ${escapeHtml(line.line_id||line.id)}</b><p class="muted small">${currency(line.remaining_cents??line.amount_cents,line.currency)} remaining · ${escapeHtml(line.batch_status||line.status||'approved')}</p></div><button class="btn sm" data-record-payout="${escapeHtml(line.line_id||line.id)}" data-line-amount="${Number(line.remaining_cents??line.amount_cents??0)}">Record payment</button></div>`).join('')}</section>`;
      main.querySelector('#platformNewConsultant').onclick=()=>consultantModal(null,context);
      main.querySelector('#platformNewPolicy').onclick=()=>commissionPolicyModal(context);
      main.querySelector('#platformAttributeConsultant').onclick=()=>attributeConsultantModal(context);
      main.querySelector('#platformNewPayout').onclick=()=>payoutBatchModal(context);
      main.querySelectorAll('[data-edit-consultant]').forEach(button=>button.onclick=()=>consultantModal(consultants.find(row=>(row.consultant_id||row.id)===button.dataset.editConsultant),context));
      main.querySelectorAll('[data-approve-accrual]').forEach(button=>button.onclick=()=>approveAccrualModal(button.dataset.approveAccrual,context));
      main.querySelectorAll('[data-forfeit-consultant]').forEach(button=>button.onclick=()=>forfeitCommissionModal(button.dataset.forfeitConsultant,context));
      main.querySelectorAll('[data-add-payout-line]').forEach(button=>button.onclick=()=>payoutLineModal(button.dataset.addPayoutLine,context));
      main.querySelectorAll('[data-approve-payout]').forEach(button=>button.onclick=()=>approvePayout(button.dataset.approvePayout,context));
      main.querySelectorAll('[data-record-payout]').forEach(button=>button.onclick=()=>recordPayoutModal(button.dataset.recordPayout,Number(button.dataset.lineAmount),context));
      CUI.focusRoute(main);
    }catch(error){showError(main,error,CUI,'Commission payable')}
  }
  function consultantModal(consultant,context) {
    const {CUI,sb}=context;
    modal({title:consultant?'Edit consultant':'New consultant',submitLabel:consultant?'Save consultant':'Create consultant',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'consultantUser',label:'User ID',value:consultant?.user_id||'',required:true,attributes:'name="user_id"'})}
      ${CUI.field({id:'consultantName',label:'Display name',value:consultant?.display_name||'',required:true,attributes:'name="display_name"'})}
      ${CUI.field({id:'consultantTier',label:'Tier',control:'select',required:true,options:['senior','junior'].map(value=>({value,label:plainLabel(value),selected:value===(consultant?.tier||'junior')})),attributes:'name="tier"'})}
      ${CUI.field({id:'consultantEmploymentStart',label:'Employment started',type:'date',value:consultant?.employment_started_on||'',required:true,attributes:'name="employment_started_on"'})}
    </div>${consultant?.active===false?'<p class="platform-route-note small">This consultant is departed. Editing preserves that status; record a deliberate reactivation as a separate reviewed policy decision.</p>':''}`,
    onSubmit:async(form,controls)=>{
      await rpc(sb,'platform_upsert_commission_consultant_v89',{
        p_consultant:consultant?.consultant_id||consultant?.id||null,
        p_user:form.get('user_id'),p_display_name:form.get('display_name'),
        p_tier:form.get('tier'),p_employment_started_on:form.get('employment_started_on'),
        p_active:consultant?.active===false?false:true
      });
      controls.close();await renderCommission(context);CUI.announce(consultant?'Consultant updated.':'Consultant created.');
    }});
  }
  function attributeConsultantModal(context) {
    const {CUI,sb}=context;
    modal({title:'Attribute consultant',submitLabel:'Attribute',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'attributeConsultant',label:'Consultant ID',required:true,attributes:'name="consultant"'})}
      ${CUI.field({id:'attributeProspect',label:'Prospect ID',attributes:'name="prospect"'})}
      ${CUI.field({id:'attributeBusiness',label:'Business ID',attributes:'name="business"'})}
      ${CUI.field({id:'attributeStarted',label:'Onboarding started at',type:'datetime-local',required:true,attributes:'name="onboarding_started_at"'})}
      <div class="wide">${CUI.field({id:'attributeReason',label:'Reason',control:'textarea',required:true,attributes:'name="reason" rows="3"'})}</div>
    </div>`,onSubmit:async(form,controls)=>{
      if(!form.get('prospect')&&!form.get('business'))throw new Error('Add a prospect ID or business ID.');
      await rpc(sb,'attribute_consultant_v78',{
        p_consultant:form.get('consultant'),p_prospect:form.get('prospect')||null,
        p_business:form.get('business')||null,
        p_onboarding_started_at:new Date(form.get('onboarding_started_at')).toISOString(),
        p_reason:form.get('reason')
      });
      controls.close();await renderCommission(context);CUI.announce('Consultant attribution recorded.');
    }});
  }
  function commissionPolicyModal(context) {
    const {CUI,sb}=context;
    modal({title:'Create commission policy',submitLabel:'Preview policy',CUI,body:`<div class="platform-form-grid">
      ${CUI.field({id:'policyRole',label:'Consultant tier',control:'select',required:true,options:['senior','junior'].map(value=>({value,label:plainLabel(value)})),attributes:'name="role"'})}
      ${CUI.field({id:'policyEffective',label:'Effective from',type:'datetime-local',required:true,attributes:'name="effective_from"'})}
      ${CUI.field({id:'policyFirst',label:'Year-one base rate (basis points)',type:'number',required:true,attributes:'name="first_year_bps" min="0" max="10000" step="1"'})}
      ${CUI.field({id:'policyAnniversary',label:'12-month service bonus (basis points)',type:'number',required:true,attributes:'name="anniversary_bonus_bps" min="0" max="10000" step="1"'})}
      ${CUI.field({id:'policyRenewal',label:'Renewal rate (basis points)',type:'number',required:true,attributes:'name="renewal_bps" min="0" step="1"'})}
      <div class="wide">${CUI.field({id:'policyReason',label:'Reason',control:'textarea',required:true,attributes:'name="reason" rows="3"'})}</div>
    </div>`,onSubmit:async(form,controls)=>{
      const values={role:form.get('role'),first_year_bps:Number(form.get('first_year_bps')),anniversary_bonus_bps:Number(form.get('anniversary_bonus_bps')),renewal_bps:Number(form.get('renewal_bps')),effective_from:new Date(form.get('effective_from')).toISOString(),reason:form.get('reason')};
      controls.close();previewThenConfirm({title:'Confirm commission policy',preview:{...values,calculation_basis:'net_of_gst'},CUI,onConfirm:async(confirmControls)=>{
        await rpc(sb,'create_consultant_commission_policy_v78',{p_tier:values.role,p_first_year_bps:values.first_year_bps,p_anniversary_bonus_bps:values.anniversary_bonus_bps,p_renewal_bps:values.renewal_bps,p_effective_from:values.effective_from,p_reason:values.reason});
        confirmControls.close();await renderCommission(context);CUI.announce('Commission policy created.');
      }});
    }});
  }
  function approveAccrualModal(accrualId,context) {
    const {CUI,sb}=context;
    modal({title:'Approve accrual',submitLabel:'Approve',CUI,body:CUI.field({id:'accrualReason',label:'Approval reason',control:'textarea',required:true,attributes:'name="reason" rows="3"'}),
      onSubmit:async(form,controls)=>{await rpc(sb,'approve_consultant_accrual_v78',{p_accrual:accrualId,p_reason:form.get('reason')});controls.close();await renderCommission(context);CUI.announce('Accrual approved.')}});
  }
  function payoutBatchModal(context) {
    const {CUI,sb}=context;
    modal({title:'New payout batch',submitLabel:'Create batch',CUI,body:`${CUI.field({id:'batchCurrency',label:'Currency',value:'SGD',required:true,attributes:'name="currency" maxlength="3"'})}${CUI.field({id:'batchNote',label:'Note',control:'textarea',attributes:'name="note" rows="3"'})}`,
      onSubmit:async(form,controls)=>{await rpc(sb,'create_consultant_payout_batch_v78',{p_currency:String(form.get('currency')).toUpperCase(),p_note:form.get('note')||null});controls.close();await renderCommission(context);CUI.announce('Payout batch created.')}});
  }
  function payoutLineModal(batchId,context) {
    const {CUI,sb}=context;
    modal({title:'Add payout line',submitLabel:'Add line',CUI,body:`${CUI.field({id:'lineAccrual',label:'Approved accrual ID',required:true,attributes:'name="accrual"'})}${CUI.field({id:'lineAmount',label:'Amount (integer cents)',type:'number',required:true,attributes:'name="amount_cents" min="1" step="1"'})}`,
      onSubmit:async(form,controls)=>{await rpc(sb,'add_consultant_payout_line_v78',{p_batch:batchId,p_accrual:form.get('accrual'),p_amount_cents:Number(form.get('amount_cents'))});controls.close();await renderCommission(context);CUI.announce('Payout line added.')}});
  }
  function approvePayout(batchId,context) {
    previewThenConfirm({title:'Approve payout batch',preview:{batch_id:batchId,action:'approve'},CUI:context.CUI,onConfirm:async controls=>{await rpc(context.sb,'approve_consultant_payout_batch_v78',{p_batch:batchId});controls.close();await renderCommission(context);context.CUI.announce('Payout batch approved.')}});
  }
  function recordPayoutModal(lineId,amount,context) {
    const {CUI,sb}=context;
    modal({title:'Record consultant payment',submitLabel:'Record payment',CUI,body:`${CUI.field({id:'paidAmount',label:'Paid amount (integer cents)',type:'number',value:String(amount),required:true,attributes:'name="amount_cents" min="1" step="1"'})}${CUI.field({id:'paidReference',label:'Payment reference',required:true,attributes:'name="reference"'})}${CUI.field({id:'paidAt',label:'Paid at',type:'datetime-local',required:true,attributes:'name="paid_at"'})}`,
      onSubmit:async(form,controls)=>{await rpc(sb,'record_consultant_payout_v78',{p_line:lineId,p_amount_cents:Number(form.get('amount_cents')),p_reference:form.get('reference'),p_paid_at:new Date(form.get('paid_at')).toISOString()});controls.close();await renderCommission(context);CUI.announce('Consultant payment recorded.')}});
  }
  function forfeitCommissionModal(consultantId,context) {
    const {CUI,sb}=context;
    modal({title:'Forfeit open commission',submitLabel:'Preview forfeiture',CUI,body:`${CUI.field({id:'departedAt',label:'Departed at',type:'datetime-local',required:true,attributes:'name="departed_at"'})}${CUI.field({id:'forfeitReason',label:'Reason',control:'textarea',required:true,attributes:'name="reason" rows="3"'})}`,
      onSubmit:async(form,controls)=>{const preview={consultant_id:consultantId,departed_at:new Date(form.get('departed_at')).toISOString(),reason:form.get('reason')};controls.close();previewThenConfirm({title:'Confirm commission forfeiture',preview,CUI,onConfirm:async confirmControls=>{await rpc(sb,'forfeit_consultant_open_commission_v78',{p_consultant:consultantId,p_departed_at:preview.departed_at,p_reason:preview.reason});confirmControls.close();await renderCommission(context);CUI.announce('Open commission forfeited.')}})}});
  }

  async function renderAutomation(context) {
    const {main,CUI,sb}=context;
    main.innerHTML=loading(CUI,'Automation','Loading reconciliation and billing event health…','retention');
    try{
      const [reconciliation,billing]=await Promise.all([
        rpc(sb,'platform_get_automation_reconciliation_v89',{p_run:null,p_limit:50}),
        rpc(sb,'platform_get_automation_billing_v89',{p_business:null,p_limit:250})
      ]);
      const runs=asArray(reconciliation?.runs),items=asArray(reconciliation?.items),rows=asArray(billing);
      const failedEvents=rows.reduce((value,row)=>value+Number(row.failed_event_count||0),0);
      main.innerHTML=`${CUI.pageHeader({title:'Automation',subtitle:'Billing reconciliation runs and provider event health from the current platform ledger.',iconName:'retention'})}
        <section class="platform-health-grid"><article class="card platform-kpi"><div class="platform-kpi-label">${CUI.icon('retention',{size:17})}<span>Reconciliation runs</span></div><div class="platform-kpi-value">${runs.length}</div></article><article class="card platform-kpi"><div class="platform-kpi-label">${CUI.icon('info',{size:17})}<span>Failed billing events</span></div><div class="platform-kpi-value">${failedEvents}</div></article><article class="card platform-kpi"><div class="platform-kpi-label">${CUI.icon('reports',{size:17})}<span>Reconciliation items</span></div><div class="platform-kpi-value">${items.length}</div></article></section>
        ${CUI.card({title:'Reconciliation history',body:runs.length?CUI.table({caption:'Billing reconciliation runs',headers:['Started','Mode','Status','Finished','Summary'],rows:runs.map(run=>[escapeHtml(dateTime(run.started_at)),escapeHtml(run.run_mode),CUI.status(run.status||'—',run.status==='completed'?'ok':run.status==='failed'?'no':'new'),escapeHtml(dateTime(run.finished_at)),escapeHtml(JSON.stringify(run.summary||{}))])}):CUI.emptyState({iconName:'retention',title:'No reconciliation runs',body:'No billing reconciliation history was returned.'})})}`;
      CUI.focusRoute(main);
    }catch(error){showError(main,error,CUI,'Automation')}
  }

  function disconnectedRouteHtml(key, CUI) {
    const content = {
      onboarding:{
        title:'Onboarding',subtitle:'Track firm onboarding from first contact through launch.',
        iconName:'setup',heading:'Onboarding system update required',
        body:'The platform console requires the reviewed onboarding data contract before it can display or change lifecycle evidence.'
      },
      billing:{
        title:'Billing',subtitle:'Review subscription and collection activity across firms.',
        iconName:'reports',heading:'Platform billing is not connected',
        body:'The current backend exposes per-firm subscription projections, not invoices, payment collection, or settlement.'
      },
      commissions:{
        title:'Commission payable',subtitle:'Review approved commission obligations and payment status.',
        iconName:'staff',heading:'Payables are not available yet',
        body:'The current product calculates commission earned inside a firm, but has no payout periods, approval state, payment reference, or paid ledger.'
      },
      sectors:{
        title:'Sector modules',subtitle:'Manage the module starting point for each business sector.',
        iconName:'packages',heading:'Sector presets are not connected',
        body:'Sector module defaults remain application configuration. No platform-managed preset data source exists yet.'
      },
      automation:{
        title:'Automation',subtitle:'Monitor platform workflows and operational runs.',
        iconName:'retention',heading:'Automation data is not connected',
        body:'No platform automation catalogue, run history, or status data source is available to this console.'
      }
    };
    return unavailable(CUI,content[key] || content.onboarding);
  }

  async function loadOverview(context) {
    const {sb,CUI,main,generation,isCurrent}=context;
    main.innerHTML=loading(CUI,'Platform overview','Combining current onboarding, firm, billing and commission truth…','platform');
    const results=await Promise.allSettled([
      rpc(sb,'super_admin_list_businesses'),
      rpc(sb,'platform_get_sme_board_v76',{p_consultant:null}),
      rpc(sb,'platform_list_prospects_v76',{p_stage:null,p_consultant:null,p_search:null,p_limit:250,p_before:null}),
      rpc(sb,'get_platform_billing_v77',{p_business:null,p_limit:250}),
      rpc(sb,'get_consultant_commission_dashboard_v78',{p_consultant:null,p_limit:100}),
      rpc(sb,'platform_list_sector_entitlements_v75')
    ]);
    if(generation!==renderGeneration||!main.isConnected||(isCurrent&&!isCurrent()))return;
    const value=index=>results[index].status==='fulfilled'?results[index].value:null;
    const firms=asArray(value(0)),board=asObject(value(1)),prospects=flattenBoard(board,value(2));
    const billing=asArray(value(3)),commission=asObject(value(4)),sectors=asObject(value(5));
    const unavailableAreas=[
      ['Firms',results[0]],['Onboarding',results[1]],['Billing',results[3]],['Commission',results[4]],['Sector modules',results[5]]
    ].filter(([,result])=>result.status==='rejected');
    const projectedMonthly=firms.reduce((sum,row)=>sum+Number(row.est_monthly_cents||0),0);
    const overdueProspects=prospects.filter(row=>row.overdue===true||Number(row.overdue_task_count||0)>0);
    const staleProspects=prospects.filter(row=>row.stale===true||row.is_stale===true);
    const billingAttention=billing.filter(row=>row.status==='past_due'||Number(row.failed_event_count||0)>0);
    const accruals=asArray(commission,['accruals','commission_accruals']);
    const commissionAttention=accruals.filter(row=>['open','payable'].includes(row.status));
    main.innerHTML=`${CUI.pageHeader({title:'Platform overview',subtitle:'A combined operational view. Unavailable backend phases remain explicit and do not produce estimated records.',iconName:'platform'})}
      ${unavailableAreas.length?`<div class="platform-route-note platform-status-note">${CUI.icon('info',{size:19})}<div><b>Partial platform data</b><p class="small">System update required for: ${escapeHtml(unavailableAreas.map(([label])=>label).join(', '))}. Available areas remain live below.</p></div></div>`:''}
      <section class="platform-kpis" aria-label="Platform summary">${[
        ['Firms',firms.length,'branch'],['Open prospects',prospects.filter(row=>!['client','activated','lost'].includes(prospectStage(row))).length,'setup'],
        ['Projected monthly',currency(projectedMonthly),'reports'],['Billing attention',billingAttention.length,'info']
      ].map(([label,metric,icon])=>`<article class="card platform-kpi"><div class="platform-kpi-label">${CUI.icon(icon,{size:17})}<span>${escapeHtml(label)}</span></div><div class="platform-kpi-value">${escapeHtml(metric)}</div></article>`).join('')}</section>
      <div class="platform-detail-grid">
        ${CUI.card({title:'Action queue',body:`<div class="platform-action-queue">${[
          ['Overdue prospect tasks',overdueProspects.length,'#/platform/onboarding'],
          ['Stale prospects',staleProspects.length,'#/platform/onboarding'],
          ['Billing records needing attention',billingAttention.length,'#/platform/billing'],
          ['Open commission accruals',commissionAttention.length,'#/platform/commissions']
        ].map(([label,count,hash])=>`<a class="platform-action-item" href="${hash}"><span>${escapeHtml(label)}</span><b>${count}</b></a>`).join('')}</div>`})}
        ${CUI.card({title:'Configuration coverage',body:detailObjectHtml({
          sector_profiles:asArray(sectors.profiles).length,
          firms_with_sector_assignment:asArray(sectors.businesses).length,
          firms_without_sector_assignment:Math.max(0,firms.length-asArray(sectors.businesses).length),
          trialing:billing.filter(row=>row.status==='trialing').length,
          active:billing.filter(row=>row.status==='active').length,
          past_due:billing.filter(row=>row.status==='past_due').length
        })})}
      </div>
      <section class="card" style="margin-top:16px">${firms.length?CUI.table({caption:'Current firm snapshot',headers:['Firm','Sector','Branches','Staff','Customers','Seats','Subscription','Projected monthly'],rows:firmRows(firms.slice(0,12),CUI),className:'platform-firms-table'}):CUI.emptyState({iconName:'branch',title:'No firm roster available',body:results[0].status==='rejected'?'The firm roster requires a system update.':'The firm roster returned no records.'})}</section>`;
    CUI.focusRoute(main);
  }

  function accessPermissionRows(grant={}) {
    const perms=asObject(grant.module_perms),role=grant.role||'admin';
    return platformModuleKeys.map(key=>{
      const current=perms[key]??perms['*']??(role==='admin'?'rw':'off');
      return `<label class="platform-permission-row" data-access-module="${key}">
        <span><b>${escapeHtml(platformModuleLabels[key])}</b><small>${key==='onboarding'?'CRM and onboarding workflow':key==='reports'?'Scoped analytics and report generation':'Platform console module'}</small></span>
        <select name="permission_${key}" aria-label="${escapeHtml(platformModuleLabels[key])} permission">
          <option value="off"${current!=='r'&&current!=='rw'?' selected':''}>Off</option>
          <option value="r"${current==='r'?' selected':''}>Read only</option>
          <option value="rw"${current==='rw'?' selected':''}>Read and write</option>
        </select>
      </label>`;
    }).join('');
  }

  function accessGrantModal(grant,context) {
    const {CUI,sb}=context,isEdit=Boolean(grant?.user_id);
    const seed=grant||{role:'admin',module_perms:Object.fromEntries(platformModuleKeys.map(key=>[key,'rw'])),active:true};
    const userPicker=isEdit
      ?`<div class="platform-route-note"><b>${escapeHtml(seed.display_name||seed.email||'Platform user')}</b><p class="small">${escapeHtml(seed.email||'Email unavailable')}</p></div><input type="hidden" name="user_id" value="${escapeHtml(seed.user_id)}">`
      :`${CUI.field({
        id:'platformAccessUserQuery',label:'Find user by email or name',required:true,
        hint:'Search an existing Nestly sign-in. You will confirm the matched person before granting access.',
        attributes:'autocomplete="off" minlength="3" maxlength="160"'
      })}
      <button type="button" class="btn ghost" id="platformAccessUserLookup">${CUI.icon('search',{size:17})}<span>Find user</span></button>
      <label for="platformAccessUser" style="margin-top:12px">Selected user</label>
      <select id="platformAccessUser" name="user_id" disabled required><option value="">Search by email or name first</option></select>
      <p id="platformAccessUserStatus" class="muted small" role="status" aria-live="polite" style="margin-top:7px"></p>`;
    const overlay=modal({
      title:isEdit?'Edit platform access':'Add platform access',
      submitLabel:isEdit?'Save access':'Grant access',CUI,
      body:`${userPicker}
      ${CUI.field({
        id:'platformAccessRole',label:'Role',control:'select',
        options:[
          {value:'admin',label:'Admin',selected:seed.role==='admin'},
          {value:'sales_staff',label:'Sales staff',selected:seed.role==='sales_staff'}
        ],attributes:'name="role"'
      })}
      <label class="platform-active-toggle"><input type="checkbox" name="active" value="yes"${seed.active!==false?' checked':''}><span><b>Active access</b><small>Turning this off removes platform access immediately without deleting history.</small></span></label>
      <fieldset class="platform-permission-editor"><legend>Module permissions</legend>
        <p class="muted small">Off modules are hidden and blocked. Read-only modules never show editing controls.</p>
        <div data-permission-rows>${accessPermissionRows(seed)}</div>
      </fieldset>`,
      onSubmit:async(form,controls)=>{
        const role=String(form.get('role')||''),perms={};
        const selectedUser=String(form.get('user_id')||'').trim();
        if(!selectedUser)throw new Error('Find and select an existing Nestly user first.');
        platformModuleKeys.forEach(key=>{
          const value=String(form.get(`permission_${key}`)||'off');
          if(value==='r'||value==='rw')perms[key]=value;
        });
        if(role==='sales_staff'){
          perms.onboarding='rw';perms.firms='r';
          if(!['r','rw'].includes(perms.reports))perms.reports='r';
          Object.keys(perms).forEach(key=>{
            if(!['onboarding','firms','reports'].includes(key))delete perms[key];
          });
        }else if(platformModuleKeys.every(key=>perms[key]==='rw')){
          Object.keys(perms).forEach(key=>delete perms[key]);
          perms['*']='rw';
        }
        await rpc(sb,'platform_upsert_access_grant_v89',{
          p_user:selectedUser,
          p_role:role,p_module_perms:perms,p_active:form.get('active')==='yes'
        });
        controls.close();await renderPlatformAccess(context);
        CUI.announce(isEdit?'Platform access updated.':'Platform access granted.');
      }
    });
    if(!isEdit){
      const query=overlay.querySelector('#platformAccessUserQuery');
      const lookup=overlay.querySelector('#platformAccessUserLookup');
      const picker=overlay.querySelector('#platformAccessUser');
      const lookupStatus=overlay.querySelector('#platformAccessUserStatus');
      lookup.onclick=async()=>{
        const value=String(query.value||'').trim();
        if(value.length<3){lookupStatus.textContent='Enter at least 3 characters of a name or email.';return}
        lookup.disabled=true;picker.disabled=true;lookupStatus.textContent='Searching existing Nestly users…';
        try{
          const payload=asObject(await rpc(sb,'platform_lookup_access_user_v89',{p_query:value}));
          const items=asArray(payload,['items']);
          picker.innerHTML=items.length
            ?`${payload.status==='ambiguous'?'<option value="" selected>Choose the correct user</option>':''}${items.map(item=>`<option value="${escapeHtml(item.user_id)}">${escapeHtml(item.display_name||'Unnamed user')} · ${escapeHtml(item.email||'Email unavailable')}</option>`).join('')}`
            :'<option value="">No matching user</option>';
          picker.disabled=!items.length;
          if(payload.status==='matched'&&items.length===1){
            picker.value=items[0].user_id;
            lookupStatus.textContent=`Selected ${items[0].display_name||items[0].email||'matched user'}.`;
          }else if(payload.status==='ambiguous'&&items.length){
            lookupStatus.textContent='More than one user matched. Choose the correct name and email.';
          }else{
            lookupStatus.textContent='No existing Nestly sign-in matched that search.';
          }
          picker.onchange=()=>{
            const item=items.find(row=>String(row.user_id)===picker.value);
            if(item)lookupStatus.textContent=`Selected ${item.display_name||item.email||'user'} · ${item.email||'Email unavailable'}.`;
          };
        }catch(error){
          picker.innerHTML='<option value="">Search unavailable</option>';
          lookupStatus.textContent=error.message||'User search is unavailable.';
        }finally{lookup.disabled=false}
      };
    }
    const roleSelect=overlay.querySelector('#platformAccessRole');
    const updateRoleHelp=()=>{
      const sales=roleSelect.value==='sales_staff';
      overlay.querySelectorAll('[data-access-module]').forEach(row=>{
        const key=row.dataset.accessModule,select=row.querySelector('select');
        if(!sales){select.disabled=false;return}
        if(key==='onboarding'){select.value='rw';select.disabled=true}
        else if(key==='firms'||key==='reports'){
          if(key==='firms')select.value='r';
          else if(!['r','rw'].includes(select.value))select.value='r';
          select.disabled=key==='firms';
        }else{select.value='off';select.disabled=true}
      });
    };
    roleSelect.onchange=updateRoleHelp;updateRoleHelp();
  }

  async function renderPlatformAccess(context) {
    const {main,CUI,sb}=context;
    main.innerHTML=loading(CUI,'Platform access','Loading administrators and sales staff…','staff');
    try{
      const payload=asObject(await rpc(sb,'platform_list_access_grants_v89'));
      const grants=asArray(payload,['items']);
      main.innerHTML=`${CUI.pageHeader({
        title:'Platform access',
        subtitle:'Super-admin control of platform roles, module permissions and active access.',
        iconName:'staff',
        actions:`<button type="button" class="btn" id="platformAddAccess">${CUI.icon('add',{size:17})}<span>Add access</span></button>`
      })}
      <div class="platform-route-note platform-status-note">${CUI.icon('info',{size:19})}<div>
        <b>Super admin remains implicit</b>
        <p class="small">Your account always has every module with read and write access. Admins default to full access and can be customized here. Sales staff are restricted to their own-created or assigned CRM records and scoped reports.</p>
      </div></div>
      <section class="platform-access-list" aria-label="Platform access grants">
        ${grants.map(grant=>`<article class="card platform-access-card">
          <div class="platform-access-card-head"><div><h2>${escapeHtml(grant.email||grant.user_id)}</h2>
            <p class="muted small">${escapeHtml(grant.user_id)}</p></div>
            ${CUI.status(grant.active?'Active':'Inactive',grant.active?'ok':'off')}
          </div>
          <dl class="platform-access-facts">
            <div><dt>Role</dt><dd>${escapeHtml(roleLabel(grant.role))}</dd></div>
            <div><dt>Scope</dt><dd>${escapeHtml(grant.role==='sales_staff'?'Own-created or assigned firms':'All permitted records')}</dd></div>
            <div><dt>Updated</dt><dd>${escapeHtml(dateTime(grant.updated_at))}</dd></div>
          </dl>
          <div class="platform-module-list" aria-label="Module permissions">${platformModuleKeys.map(key=>{
            const permission=grant.module_perms?.[key]??grant.module_perms?.['*']??'off';
            return permission==='off'?'':`<span class="chip ${permission==='rw'?'on':''}">${escapeHtml(platformModuleLabels[key])} · ${permission==='rw'?'write':'read'}</span>`;
          }).join('')||'<span class="muted small">No modules enabled</span>'}</div>
          <div class="platform-actions platform-access-actions"><button type="button" class="btn ghost" data-edit-access="${escapeHtml(grant.user_id)}">${CUI.icon('edit',{size:17})}<span>Edit access</span></button></div>
        </article>`).join('')||CUI.emptyState({iconName:'staff',title:'No delegated platform users',body:'Add an admin or sales staff account when you are ready.'})}
      </section>`;
      main.querySelector('#platformAddAccess').onclick=()=>accessGrantModal(null,context);
      main.querySelectorAll('[data-edit-access]').forEach(button=>{
        button.onclick=()=>accessGrantModal(grants.find(grant=>String(grant.user_id)===button.dataset.editAccess),context);
      });
      CUI.focusRoute(main);
    }catch(error){showError(main,error,CUI,'Platform access')}
  }

  function scopedScopeNote(access,CUI) {
    return `<div class="platform-route-note platform-status-note">${CUI.icon('info',{size:19})}<div>
      <b>${escapeHtml(roleLabel(access.role))} · ${escapeHtml(scopeLabel(access.scope))}</b>
      <p class="small">${access.scope==='own_created_or_assigned'
        ?'Search, counts, details and reports use the same server-enforced scope. Other sales staff records are never included.'
        :'This module covers every record permitted by your platform role.'}</p>
    </div></div>`;
  }

  async function fetchScopedFirms(sb,search='') {
    return asObject(await rpc(sb,'platform_list_my_firms_v89',{
      p_search:search||null,p_limit:250
    }));
  }

  function canAssignScopedProspect(context) {
    return context?.canWrite===true&&context?.access?.role==='admin'
      &&context?.access?.scope==='all';
  }

  function scopedConsultantOptions(rows=[]) {
    const unique=new Map();
    asArray(rows).forEach(row=>{
      const id=String(row.id||row.consultant_id||row.assigned_consultant_id||'');
      const name=String(row.display_name||row.consultant_name||row.owner_name||'').trim();
      if(id&&name&&row.active!==false)unique.set(id,{value:id,label:name});
    });
    return [...unique.values()].sort((left,right)=>left.label.localeCompare(right.label));
  }

  async function fetchScopedConsultants(sb,firmRows=[]) {
    const payload=asObject(await rpc(sb,'platform_list_assignment_consultants_v89'));
    const directory=asArray(payload,['items']);
    return scopedConsultantOptions([...directory,...asArray(firmRows)]);
  }

  function scopedFirmTable(items,CUI) {
    return CUI.table({
      caption:'Firms in your access scope',
      headers:['Firm','Stage','Owner','Contact','Attention','Updated'],
      rows:items.map(item=>[
        `<b>${escapeHtml(item.name||item.legal_name||'Unnamed firm')}</b>${item.registration_number?`<span class="muted small platform-firm-secondary">${escapeHtml(item.registration_number)}</span>`:''}`,
        escapeHtml(plainLabel(prospectStage(item))),
        escapeHtml(item.consultant_name||item.owner_name||(item.assigned_consultant_id?'Assigned':'Unassigned')),
        `<span>${escapeHtml(item.boss_name||item.primary_contact_name||'—')}</span>${platformContactActions(item.boss_phone||item.primary_contact_phone,CUI,{compact:true})}`,
        item.attention_due?CUI.status('Due now','no'):CUI.status(plainLabel(item.attention_severity||'Clear'),item.attention_severity==='critical'?'no':'off'),
        escapeHtml(dateTime(item.updated_at))
      ]),className:'platform-scoped-firms-table'
    });
  }

  async function renderScopedFirms(context,search='') {
    const {main,CUI,sb,access}=context;
    main.innerHTML=loading(CUI,'Firms','Loading firms in your access scope…','branch');
    try{
      const payload=await fetchScopedFirms(sb,search),items=asArray(payload,['items']);
      main.innerHTML=`${CUI.pageHeader({title:'Firms',subtitle:'Search the firms available to your platform role.',iconName:'branch'})}
        ${scopedScopeNote(access,CUI)}
        <form class="card platform-scoped-search" id="platformScopedFirmSearch">
          ${CUI.field({id:'platformScopedFirmQuery',label:'Search firms',type:'search',value:search,placeholder:'Company, UEN, owner, email or phone'})}
          <button class="btn" type="submit">${CUI.icon('search',{size:17})}<span>Search</span></button>
        </form>
        ${payload.truncated?`<p class="platform-route-note">Showing the first 250 matches. Refine the search to narrow the list.</p>`:''}
        <section class="card">${items.length?scopedFirmTable(items,CUI):CUI.emptyState({iconName:'branch',title:'No firms in scope',body:'Try another search or ask a super admin to review assignments.'})}</section>`;
      main.querySelector('#platformScopedFirmSearch').onsubmit=event=>{
        event.preventDefault();renderScopedFirms(context,main.querySelector('#platformScopedFirmQuery').value.trim());
      };
      CUI.focusRoute(main);
    }catch(error){showError(main,error,CUI,'Firms')}
  }

  function scopedActivityModal(prospectId,context,onSaved) {
    const {CUI,sb}=context;
    modal({
      title:'Record CRM activity',submitLabel:'Save activity',CUI,
      body:`${CUI.field({id:'scopedActivityType',label:'Activity type',control:'select',options:[
        'note','call','email','whatsapp','meeting','demo','proposal_sent','contract_sent'
      ].map(value=>({value,label:plainLabel(value)})),attributes:'name="activity_type"'})}
      ${CUI.field({id:'scopedActivitySummary',label:'Summary',required:true,attributes:'name="summary" minlength="2" maxlength="240"'})}
      ${CUI.field({id:'scopedActivityDetail',label:'Detail',control:'textarea',attributes:'name="detail" rows="4"'})}`,
      onSubmit:async(form,controls)=>{
        await rpc(sb,'platform_add_my_prospect_activity_v89',{
          p_prospect:prospectId,p_activity_type:form.get('activity_type'),
          p_summary:form.get('summary'),p_detail:form.get('detail')||null,
          p_occurred_at:new Date().toISOString()
        });
        controls.close();await onSaved?.();CUI.announce('Activity saved.');
      }
    });
  }

  function scopedProspectCreateModal(context,onSaved) {
    const {CUI,sb}=context;
    modal({
      title:'Add firm to CRM',submitLabel:'Create firm',CUI,
      body:`${CUI.field({id:'scopedNewCompany',label:'Company name',required:true,attributes:'name="company_name" minlength="2" maxlength="200"'})}
      ${CUI.field({id:'scopedNewContact',label:'Boss / primary contact name',attributes:'name="contact_name" maxlength="200"'})}
      ${CUI.field({id:'scopedNewPhone',label:'Phone number',type:'tel',hint:'Add a phone number or email address.',attributes:'name="phone" autocomplete="tel"'})}
      ${CUI.field({id:'scopedNewEmail',label:'Email',type:'email',attributes:'name="email" autocomplete="email"'})}
      ${CUI.field({id:'scopedNewSector',label:'Sector key (optional)',hint:'For example: fnb, facial, salon or fitness. Leave blank if undecided.',attributes:'name="sector_key" autocapitalize="none"'})}`,
      onSubmit:async(form,controls)=>{
        if(!String(form.get('phone')||'').trim()&&!String(form.get('email')||'').trim()){
          throw new Error('Add a phone number or email address.');
        }
        await rpc(sb,'platform_create_my_prospect_v89',{
          p_company_name:form.get('company_name'),
          p_sector_key:String(form.get('sector_key')||'').trim()||null,
          p_phone:String(form.get('phone')||'').trim()||null,
          p_email:String(form.get('email')||'').trim()||null,
          p_contact_name:String(form.get('contact_name')||'').trim()||null
        });
        controls.close();await onSaved?.();CUI.announce('Firm added to your CRM.');
      }
    });
  }

  function scopedTaskModal(prospectId,context,onSaved) {
    const {CUI,sb}=context;
    modal({
      title:'Add follow-up task',submitLabel:'Create task',CUI,
      body:`${CUI.field({id:'scopedTaskTitle',label:'Task',required:true,attributes:'name="title" minlength="2" maxlength="240"'})}
      ${CUI.field({id:'scopedTaskDue',label:'Due at',type:'datetime-local',required:true,attributes:'name="due_at"'})}`,
      onSubmit:async(form,controls)=>{
        await rpc(sb,'platform_create_my_prospect_task_v89',{
          p_prospect:prospectId,p_title:form.get('title'),
          p_due_at:new Date(form.get('due_at')).toISOString()
        });
        controls.close();await onSaved?.();CUI.announce('Task created.');
      }
    });
  }

  function scopedProspectAssignmentModal(prospect,consultants,context,onSaved) {
    if(!canAssignScopedProspect(context))return;
    const current=String(prospect.assigned_consultant_id||prospect.consultant_id||'');
    modal({
      title:'Assign sales consultant',submitLabel:'Save assignment',CUI:context.CUI,
      body:`${context.CUI.field({
        id:'scopedAssignmentConsultant',label:'Sales consultant',control:'select',
        options:[{value:'',label:'Unassigned'},...consultants].map(option=>({
          ...option,selected:String(option.value)===current
        })),attributes:'name="consultant"'
      })}
      <p class="muted small">Choose by consultant name. Sales staff continue to see only firms they created or are assigned to.</p>`,
      onSubmit:async(form,controls)=>{
        await rpc(context.sb,'platform_assign_prospect_v89',{
          p_prospect:prospect.id||prospect.prospect_id,
          p_consultant:String(form.get('consultant')||'')||null,
          p_reason:'admin assignment from scoped onboarding'
        });
        controls.close();await onSaved?.();context.CUI.announce('Consultant assignment updated.');
      }
    });
  }

  async function openScopedProspect(item,context,consultants=[]) {
    const {CUI,sb}=context,prospectId=item.prospect_id||item.id;
    if(!prospectId)return;
    const overlay=document.createElement('div');
    overlay.className='platform-drawer';overlay.tabIndex=-1;
    overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');
    overlay.setAttribute('aria-labelledby','scopedProspectTitle');
    overlay.innerHTML=`<section class="platform-drawer-panel"><div class="platform-drawer-head">
      <div><h1 id="scopedProspectTitle" style="font-size:1.45rem">${escapeHtml(prospectCompany(item))}</h1>
      <p class="muted small">${escapeHtml(scopeLabel(context.access.scope))}</p></div>
      <button type="button" class="btn ghost sm platform-drawer-close" aria-label="Close detail">${CUI.icon('close',{size:18})}</button>
      </div><div data-detail>${CUI.loadingState({title:'Prospect detail',body:'Loading scoped contacts, activity and tasks…',iconName:'customers'})}</div></section>`;
    document.body.appendChild(overlay);
    let deactivate;
    const close=()=>closeOverlay(overlay,deactivate);
    overlay.querySelector('.platform-drawer-close').onclick=close;
    deactivate=CUI.activateDialog(overlay,{onClose:close});
    const renderDetail=async()=>{
      const host=overlay.querySelector('[data-detail]');
      try{
        const detail=asObject(await rpc(sb,'platform_get_my_prospect_v89',{p_prospect:prospectId}));
        const prospect=asObject(detail.prospect),company=asObject(detail.company);
        const assignment=asObject(detail.assignment);
        const contacts=asArray(detail.contacts),activities=asArray(detail.activities),tasks=asArray(detail.tasks);
        host.innerHTML=`<div class="platform-detail-shortcuts platform-actions">
          ${context.canWrite?`<button type="button" class="btn" data-add-note>${CUI.icon('add',{size:16})}<span>Add activity</span></button>
          <button type="button" class="btn ghost" data-add-task>${CUI.icon('appointments',{size:16})}<span>Add task</span></button>`:''}
          ${canAssignScopedProspect(context)?`<button type="button" class="btn ghost" data-scoped-assign>${CUI.icon('staff',{size:16})}<span>${prospect.assigned_consultant_id?'Reassign consultant':'Assign consultant'}</span></button>`:''}
        </div>
        <div class="platform-detail-grid">
          ${CUI.card({title:'Company',body:detailObjectHtml({
            legal_name:company.legal_name||company.trading_name,
            registration_number:company.registration_number,
            stage:plainLabel(prospectStage(prospect)),
            priority:plainLabel(prospect.priority||'normal'),
            sales_consultant:assignment.display_name||assignment.consultant_name||prospect.consultant_name||'Unassigned'
          })})}
          ${CUI.card({title:'Primary contact',body:contacts.length?contacts.map(contact=>`<div class="platform-action-item"><div><b>${escapeHtml(contact.full_name||contact.name||'Contact')}</b><p class="muted small">${escapeHtml(contact.email||contact.phone||'No contact detail')}</p></div>${platformContactActions(contact.phone,CUI,{compact:true})}</div>`).join(''):'<p class="muted small">No active contacts.</p>'})}
        </div>
        <section class="card platform-detail-section"><h2>Activity</h2>${activities.length?activities.map(activity=>`<div class="platform-timeline-item"><span class="platform-timeline-marker"></span><div><b>${escapeHtml(activity.summary||plainLabel(activity.activity_type))}</b><p class="muted small">${escapeHtml(dateTime(activity.occurred_at))}</p></div></div>`).join(''):'<p class="muted small">No activity recorded.</p>'}</section>
        <section class="card platform-detail-section"><h2>Tasks</h2>${tasks.length?tasks.map(task=>`<div class="platform-action-item"><div><b>${escapeHtml(task.title)}</b><p class="muted small">${escapeHtml(plainLabel(task.status||'open'))} · due ${escapeHtml(dateTime(task.due_at))}</p></div>${context.canWrite&&task.status!=='completed'?`<button type="button" class="btn ghost sm" data-complete-task="${escapeHtml(task.id)}">Complete</button>`:''}</div>`).join(''):'<p class="muted small">No tasks.</p>'}</section>`;
        host.querySelector('[data-add-note]')?.addEventListener('click',()=>scopedActivityModal(prospectId,context,renderDetail));
        host.querySelector('[data-add-task]')?.addEventListener('click',()=>scopedTaskModal(prospectId,context,renderDetail));
        host.querySelector('[data-scoped-assign]')?.addEventListener('click',()=>
          scopedProspectAssignmentModal(prospect,consultants,context,renderDetail)
        );
        host.querySelectorAll('[data-complete-task]').forEach(button=>button.onclick=()=>modal({
          title:'Complete task',submitLabel:'Mark complete',CUI,
          body:CUI.field({id:'scopedTaskOutcome',label:'Outcome',control:'textarea',required:true,attributes:'name="outcome" rows="4" minlength="2"'}),
          onSubmit:async(form,controls)=>{
            await rpc(sb,'platform_complete_my_prospect_task_v89',{p_task:button.dataset.completeTask,p_outcome:form.get('outcome')});
            controls.close();await renderDetail();CUI.announce('Task completed.');
          }
        }));
      }catch(error){host.innerHTML=CUI.errorState({title:'Prospect unavailable',message:error.message||'Try again.'})}
    };
    await renderDetail();
  }

  async function renderScopedOnboarding(context,search='') {
    const {main,CUI,sb,access}=context;
    main.innerHTML=loading(CUI,'Onboarding','Loading your scoped CRM pipeline…','setup');
    try{
      const payload=await fetchScopedFirms(sb,search),items=asArray(payload,['items']);
      const consultants=canAssignScopedProspect(context)
        ?await fetchScopedConsultants(sb,items):[];
      main.innerHTML=`${CUI.pageHeader({
        title:'Onboarding',subtitle:access.scope==='own_created_or_assigned'
          ?'Manage only the firms you created or are assigned to.'
          :'Manage the firms available to your platform role.',
        iconName:'setup',
        actions:context.canWrite?`<button type="button" class="btn" id="platformScopedNewProspect">${CUI.icon('add',{size:17})}<span>Add firm</span></button>`:''
      })}${scopedScopeNote(access,CUI)}
      <form class="card platform-scoped-search" id="platformScopedOnboardingSearch">
        ${CUI.field({id:'platformScopedOnboardingQuery',label:'Search your CRM',type:'search',value:search,placeholder:'Company, owner, email, phone or UEN'})}
        <button class="btn" type="submit">${CUI.icon('search',{size:17})}<span>Search</span></button>
      </form>
      <div class="platform-kanban" aria-label="Scoped onboarding Kanban">${operationalLanes.map(lane=>{
        const laneItems=items.filter(item=>operationalLaneFor(item)===lane.key);
        return `<section class="platform-kanban-column" aria-labelledby="scoped-lane-${lane.key}">
          <header class="platform-kanban-head"><div><h2 id="scoped-lane-${lane.key}">${escapeHtml(lane.label)}</h2><p>${escapeHtml(lane.description)}</p></div><span class="platform-count">${laneItems.length}</span></header>
          <div class="platform-card-list">${laneItems.map(item=>prospectCardHtml(item,CUI,{canWrite:context.canWrite})).join('')||'<p class="muted small platform-lane-empty">No firms</p>'}</div>
        </section>`;
      }).join('')}</div>
      <div class="platform-prospect-list" aria-label="Scoped onboarding list">${items.map(item=>prospectCardHtml(item,CUI,{mobile:true,canWrite:context.canWrite})).join('')||CUI.emptyState({iconName:'setup',title:'No firms in scope',body:'Try another search or ask a super admin to review assignments.'})}</div>`;
      main.querySelector('#platformScopedOnboardingSearch').onsubmit=event=>{
        event.preventDefault();renderScopedOnboarding(context,main.querySelector('#platformScopedOnboardingQuery').value.trim());
      };
      main.querySelector('#platformScopedNewProspect')?.addEventListener('click',()=>
        scopedProspectCreateModal(context,()=>renderScopedOnboarding(context,search))
      );
      main.querySelectorAll('[data-move]').forEach(button=>{
        button.onclick=async event=>{
          event.stopPropagation();
          const card=button.closest('[data-prospect]'),item=items.find(row=>String(row.id||row.prospect_id||row.row_id||row.business_id)===card.dataset.prospect);
          button.disabled=true;
          try{
            await rpc(sb,'platform_move_my_prospect_stage_v89',{
              p_prospect:item.prospect_id||item.id,
              p_to_stage:card.querySelector('[data-move-select]').value,
              p_expected_version:prospectVersion(item),p_reason:null
            });
            await renderScopedOnboarding(context,search);CUI.announce('Prospect stage updated.');
          }catch(error){button.disabled=false;CUI.announce(error.message||'Stage could not be updated.',{assertive:true})}
        };
      });
      main.querySelectorAll('[data-prospect]').forEach(card=>{
        const item=items.find(row=>String(row.id||row.prospect_id||row.row_id||row.business_id)===card.dataset.prospect);
        const open=()=>openScopedProspect(item,context,consultants);
        card.onclick=event=>{if(event.target.closest('[data-card-actions]'))return;open()};
        card.onkeydown=event=>{if((event.key==='Enter'||event.key===' ')&&!event.target.closest('[data-card-actions]')){event.preventDefault();open()}};
      });
      CUI.focusRoute(main);
    }catch(error){showError(main,error,CUI,'Onboarding')}
  }

  function scopedReportHtml(report,CUI) {
    const summary=asObject(report.summary);
    return `<article class="card platform-report-sheet">
      <header><h2>Scoped performance report</h2><p class="muted small">${escapeHtml(dateTime(report.scope?.generated_at))}</p></header>
      <section class="platform-kpis" aria-label="Report summary">${[
        ['Businesses',summary.business_count||0,'branch'],
        ['Customers',summary.customer_count||0,'customers'],
        ['Sales',summary.sales_count||0,'till'],
        ['Revenue',currency(summary.revenue_cents||0),'reports']
      ].map(([label,value,icon])=>`<article class="platform-kpi"><div class="platform-kpi-label">${CUI.icon(icon,{size:17})}<span>${escapeHtml(label)}</span></div><div class="platform-kpi-value">${escapeHtml(value)}</div></article>`).join('')}</section>
      ${CUI.table({caption:'Business performance',headers:['Business','Sector','Customers','Revenue'],rows:asArray(report.businesses).map(row=>[
        escapeHtml(row.name),escapeHtml(plainLabel(row.industry)),String(row.customers||0),currency(row.revenue_cents||0)
      ])})}
    </article>`;
  }

  async function renderScopedReports(context) {
    const {main,CUI,sb,access}=context;
    main.innerHTML=loading(CUI,'Reports','Loading your report scope…','reports');
    try{
      const firms=asArray(await fetchScopedFirms(sb),['items']).filter(item=>item.business_id);
      main.innerHTML=`${CUI.pageHeader({title:'Reports',subtitle:'Generate analysis using only firms inside your platform scope.',iconName:'reports'})}
        ${scopedScopeNote(access,CUI)}
        <form class="card platform-scoped-report-form" id="platformScopedReportForm">
          <fieldset><legend>Choose one assigned firm</legend><p class="muted small">The database verifies the assignment again before returning customer intelligence.</p>
            <div class="platform-scoped-report-options">${firms.map((item,index)=>`<label><input type="radio" name="business" value="${escapeHtml(item.business_id)}"${index===0?' checked':''}><span><b>${escapeHtml(item.name||item.legal_name)}</b><small>${escapeHtml(plainLabel(item.sector_key||item.industry))}</small></span></label>`).join('')}</div>
          </fieldset>
          <div class="platform-form-grid">
            ${CUI.field({id:'platformScopedReportFrom',label:'From',type:'date',value:enterpriseDefaults().from,required:true,attributes:'name="from"'})}
            ${CUI.field({id:'platformScopedReportTo',label:'To',type:'date',value:enterpriseDefaults().to,required:true,attributes:'name="to"'})}
          </div>
          <button class="btn" type="submit">${CUI.icon('reports',{size:17})}<span>Generate report</span></button>
        </form>
        <section id="platformScopedReportResult" class="platform-report-host" aria-live="polite">${CUI.emptyState({iconName:'reports',title:'Choose a firm to report on',body:'Customer groups, product and service patterns, and consultative actions will appear here when the evidence threshold is met.'})}</section>`;
      main.querySelector('#platformScopedReportForm').onsubmit=async event=>{
        event.preventDefault();
        const selected=event.currentTarget.querySelector('input[name="business"]:checked')?.value;
        const from=main.querySelector('#platformScopedReportFrom').value;
        const to=main.querySelector('#platformScopedReportTo').value;
        const host=main.querySelector('#platformScopedReportResult');
        if(!selected){CUI.announce('Select one firm.',{assertive:true});return}
        host.innerHTML=CUI.loadingState({title:'Generating consultant brief',body:'Reconciling customer, product and service evidence…',iconName:'reports'});
        try{
          const [report,affinity,recommendations]=await Promise.all([
            rpc(sb,'platform_get_assigned_firm_report_v94',{
              p_business:selected,p_branch:null,p_from:from,p_to:to
            }),
            rpc(sb,'platform_get_catalogue_affinity_v94',{
              p_business:selected,p_branch:null,p_from:from,p_to:to,p_limit:25
            }),
            rpc(sb,'platform_get_consultative_recommendations_v94',{
              p_business:selected,p_branch:null,p_from:from,p_to:to
            })
          ]);
          host.innerHTML=consultativeIntelligenceHtml(
            asObject(report),asObject(affinity),asObject(recommendations),CUI
          );
        }catch(error){host.innerHTML=CUI.errorState({title:'Report unavailable',message:error.message||'Try again.'})}
      };
      CUI.focusRoute(main);
    }catch(error){showError(main,error,CUI,'Reports')}
  }

  async function renderScopedOverview(context) {
    const {main,CUI,sb,access}=context;
    main.innerHTML=loading(CUI,'Platform overview','Loading your permitted firm summary…','platform');
    try{
      const payload=await fetchScopedFirms(sb),items=asArray(payload,['items']);
      const prospects=items.filter(item=>item.prospect_id);
      const active=items.filter(item=>['activated','client','account_created','onboarding'].includes(prospectStage(item)));
      const due=items.filter(item=>item.attention_due===true);
      main.innerHTML=`${CUI.pageHeader({
        title:'Platform overview',
        subtitle:'A role-aware summary built from the same server-enforced firm scope as search and reports.',
        iconName:'platform'
      })}${scopedScopeNote(access,CUI)}
      <section class="platform-kpis" aria-label="Scoped platform summary">${[
        ['Firms in scope',items.length,'branch'],
        ['CRM records',prospects.length,'customers'],
        ['Case won / onboarding',active.length,'setup'],
        ['Need attention',due.length,'info']
      ].map(([label,value,icon])=>`<article class="card platform-kpi"><div class="platform-kpi-label">${CUI.icon(icon,{size:17})}<span>${escapeHtml(label)}</span></div><div class="platform-kpi-value">${escapeHtml(value)}</div></article>`).join('')}</section>
      <div class="platform-detail-grid">
        ${CUI.card({title:'Next actions',body:`<div class="platform-action-queue">
          <a class="platform-action-item" href="#/platform/onboarding"><span>Review attention queue</span><b>${due.length}</b></a>
          <a class="platform-action-item" href="#/platform/firms"><span>Open firm directory</span><b>${items.length}</b></a>
          ${canAccessModule(access,'reports')?'<a class="platform-action-item" href="#/platform/reports"><span>Generate scoped report</span><b>Open</b></a>':''}
        </div>`})}
        ${CUI.card({title:'Access',body:detailObjectHtml({
          role:roleLabel(access.role),
          data_scope:scopeLabel(access.scope),
          overview_permission:modulePermission(access,'overview')
        })})}
      </div>`;
      CUI.focusRoute(main);
    }catch(error){showError(main,error,CUI,'Platform overview')}
  }

  async function loadRoster({sb,CUI,main,key,generation,isCurrent}) {
    if(key==='overview')return loadOverview({sb,CUI,main,key,generation,isCurrent});
    main.innerHTML = loading(
      CUI,
      key === 'firms' ? 'Firms' : 'Platform overview',
      'Loading the current super-admin firm roster…',
      key === 'firms' ? 'branch' : 'platform'
    );
    const {data,error} = await sb.rpc('super_admin_list_businesses');
    if (generation !== renderGeneration || !main.isConnected || (isCurrent && !isCurrent())) return;
    if (error) {
      main.innerHTML = CUI.errorState({
        title:'Platform console unavailable',
        message:'The super-admin firm roster could not be loaded for this account.',
        retryId:'platformRosterRetry'
      });
      const retry = main.querySelector('#platformRosterRetry');
      if (retry) retry.onclick = () => loadRoster({sb,CUI,main,key,generation,isCurrent});
      CUI.focusRoute(main);
      return;
    }
    const rows = Array.isArray(data) ? data : [];
    main.innerHTML = key === 'firms' ? firmsHtml(rows,CUI) : overviewHtml(rows,CUI);
    CUI.focusRoute(main);
  }

  async function render({root,sb,CUI,brand,hash,isCurrent,onSignOut,workspaceHash='#/'} = {}) {
    if (!root || !sb || !CUI) throw new Error('Platform console dependencies are unavailable.');
    const generation = ++renderGeneration;
    readOnlyObserver?.disconnect();readOnlyObserver=null;
    let access;
    try{
      access=normalizePlatformAccess(await rpc(sb,'platform_list_my_access_v89'));
      if(!access)throw new Error('Platform access is required.');
    }catch(error){
      root.innerHTML=platformAccessDeniedHtml({
        CUI,brand:brand||globalObject.NestlyBrand||{},workspaceHash,onSignOut
      });
      const deniedSignOut=root.querySelector('#platformDeniedSignOut');
      if(deniedSignOut)deniedSignOut.onclick=()=>onSignOut?.();
      CUI.focusRoute(root.querySelector('#platformMain'));
      return;
    }
    const allowedRoutes=visibleRoutes(access);
    const requestedKey=routeKey(hash);
    const activeRoute=allowedRoutes.find(route=>route.key===requestedKey)||allowedRoutes[0];
    if(!activeRoute){
      root.innerHTML=platformAccessDeniedHtml({
        CUI,brand:brand||globalObject.NestlyBrand||{},workspaceHash,onSignOut
      });return;
    }
    const activeKey=activeRoute.key;
    if(activeKey!==requestedKey&&globalObject.history?.replaceState){
      globalObject.history.replaceState(null,'',activeRoute.hash);
    }
    root.innerHTML = shellHtml({
      CUI,
      brand:brand || globalObject.NestlyBrand || {},
      activeKey,
      workspaceHash,access,allowedRoutes
    });
    const signOut = root.querySelector('#platformSignOut');
    if (signOut) signOut.onclick = () => onSignOut?.();
    const main = root.querySelector('#platformMain');
    const context={
      root,main,sb,CUI,brand:brand||globalObject.NestlyBrand||{},hash,isCurrent,
      onSignOut,workspaceHash,generation,access,activeKey,
      canWrite:activeKey==='access'||canWriteModule(access,activeKey)
    };
    activeContext=context;
    let task;
    const useScopedV89=access.role!=='super_admin';
    if(activeKey==='access')task=renderPlatformAccess(context);
    else if(useScopedV89&&activeKey==='onboarding')task=renderScopedOnboarding(context);
    else if(useScopedV89&&activeKey==='firms')task=renderScopedFirms(context);
    else if(useScopedV89&&activeKey==='reports')task=renderScopedReports(context);
    if (activeKey === 'overview') {
      task=access.role==='super_admin'
        ?loadRoster({sb,CUI,main,key:activeKey,generation,isCurrent})
        :renderScopedOverview(context);
    }
    if(!task&&activeKey==='firms')task=renderEnterprise(context);
    if(!task&&activeKey==='reports')task=renderPlatformReports(context);
    if(!task&&activeKey==='onboarding')task=renderOnboarding(context);
    if(!task&&activeKey==='billing')task=renderBilling(context);
    if(!task&&activeKey==='commissions')task=renderCommission(context);
    if(!task&&activeKey==='sectors')task=renderSectors(context);
    if(!task&&activeKey==='automation')task=renderAutomation(context);
    if(!task){
      main.innerHTML=disconnectedRouteHtml(activeKey,CUI);CUI.focusRoute(main);
    }else await task;
    installReadOnlyGuard(context);
  }

  globalObject.NestlyPlatformConsole = Object.freeze({
    isRoute,routeKey,render,routes,prospectStages,operationalLanes,
    normalizePlatformAccess,modulePermission,canAccessModule,canWriteModule,superAdminOnly,reportSectionAccess,isFullLegacyAdmin,visibleRoutes,
    operationalLaneFor,prospectAttentionMatches,normalizePlatformPhone,moduleLabel,
    firmId,resolveEnterpriseSearchBusinessIds,canAssignScopedProspect,scopedConsultantOptions
  });
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
      isRoute,routeKey,routes,prospectStages,operationalLanes,
      normalizePlatformAccess,modulePermission,canAccessModule,canWriteModule,superAdminOnly,reportSectionAccess,isFullLegacyAdmin,visibleRoutes,
      operationalLaneFor,prospectAttentionMatches,normalizePlatformPhone,moduleLabel,
      firmId,resolveEnterpriseSearchBusinessIds,canAssignScopedProspect,scopedConsultantOptions
    };
  }
})(typeof window !== 'undefined' ? window : globalThis);
