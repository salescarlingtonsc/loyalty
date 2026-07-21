(function customerUiFactory(global){
  'use strict';

  const paths={
    home:'M3 10.8 12 3l9 7.8v9.7a.5.5 0 0 1-.5.5H15v-6H9v6H3.5a.5.5 0 0 1-.5-.5z',
    customers:'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75',
    till:'M4 6h16v12H4zM8 10h8M8 14h3M16 14h.01',
    loyalty:'M20 12v10H4V12M2 7h20v5H2zM12 22V7M12 7H7.5A2.5 2.5 0 1 1 10 4.5C10 6 12 7 12 7Zm0 0h4.5A2.5 2.5 0 1 0 14 4.5C14 6 12 7 12 7Z',
    retention:'M20 7h-5V2M4 17h5v5M20 7a8 8 0 0 0-13.7-2.7L4 7m0 10a8 8 0 0 0 13.7 2.7L20 17',
    referrals:'M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M8.5 13a4 4 0 1 0 0-8 4 4 0 0 0 0 8M17 8h6M20 5v6',
    memberships:'M12 3 4 7l8 14 8-14zM4 7h16M8 7l4 14 4-14',
    giftcard:'M20 12v9H4v-9M2 7h20v5H2zM12 21V7M12 7H7.5A2.5 2.5 0 1 1 10 4.5C10 6 12 7 12 7Zm0 0h4.5A2.5 2.5 0 1 0 14 4.5C14 6 12 7 12 7Z',
    appointments:'M7 3v4M17 3v4M3 9h18M5 5h14a2 2 0 0 1 2 2v13H3V7a2 2 0 0 1 2-2Z',
    sales:'M6 2h12v20l-3-2-3 2-3-2-3 2zM9 7h6M9 11h6M9 15h3',
    services:'M14.7 6.3a4 4 0 0 0-5-5L7 4 4 7 1.3 4.3a4 4 0 0 0 5 5L15 18a2.1 2.1 0 1 0 3-3z',
    bookings:'M6 2v4M18 2v4M3 8h18M5 4h14a2 2 0 0 1 2 2v15H3V6a2 2 0 0 1 2-2Zm3 9h6v6H9z',
    waitlist:'M6 2h12M6 22h12M8 2v5l4 5-4 5v5M16 2v5l-4 5 4 5v5',
    inventory:'M21 8 12 3 3 8l9 5 9-5ZM3 8v8l9 5 9-5V8M12 13v8',
    packages:'M20 12v9H4v-9M2 7h20v5H2zM12 21V7',
    branch:'M4 22V4h10v18M14 10h6v12M8 8h2M8 12h2M8 16h2M17 14h.01M17 18h.01M2 22h20',
    reports:'M4 20V10M10 20V4M16 20v-7M22 20V7M2 20h22',
    staff:'M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M8.5 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8M20 8v6M17 11h6',
    daily:'M4 4h16v16H4zM8 2v4M16 2v4M4 9h16M8 13h3M8 17h6',
    pnl:'M3 3v18h18M7 16l4-5 4 3 5-7',
    expenses:'M12 2v20M17 6.5A4.5 4.5 0 0 0 12.5 3h-1A4.5 4.5 0 0 0 7 7.5c0 6 10 3 10 9A4.5 4.5 0 0 1 12.5 21h-1A4.5 4.5 0 0 1 7 17.5',
    settings:'M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7ZM19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.12 2.12-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1 1.56V20h-3v-.08a1.7 1.7 0 0 0-1-1.56 1.7 1.7 0 0 0-1.88.34l-.06.06-2.12-2.12.06-.06A1.7 1.7 0 0 0 7 14.7a1.7 1.7 0 0 0-1.56-1H5v-3h.08a1.7 1.7 0 0 0 1.56-1A1.7 1.7 0 0 0 6.3 8.8l-.06-.06 2.12-2.12.06.06A1.7 1.7 0 0 0 10.3 7a1.7 1.7 0 0 0 1-1.56V5h3v.08a1.7 1.7 0 0 0 1 1.56 1.7 1.7 0 0 0 1.88-.34l.06-.06 2.12 2.12-.06.06A1.7 1.7 0 0 0 19 10.3a1.7 1.7 0 0 0 1.56 1H21v3h-.08a1.7 1.7 0 0 0-1.52.7Z',
    setup:'m5 12 4 4L19 6M4 3h16v18H4z',
    platform:'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10Zm-3-10 2 2 4-4',
    wallet:'M3 7h18v13H3zM3 9V6a2 2 0 0 1 2-2h13M16 13h5',
    bell:'M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4',
    export:'M12 3v12M7 10l5 5 5-5M4 21h16',
    import:'M12 21V9M7 14l5-5 5 5M4 3h16',
    add:'M12 5v14M5 12h14',
    back:'m15 18-6-6 6-6',
    forward:'m9 18 6-6-6-6',
    search:'m21 21-4.35-4.35M19 11a8 8 0 1 1-16 0 8 8 0 0 1 16 0Z',
    redeem:'M12 2v20M17 6.5A4.5 4.5 0 0 0 12.5 3h-1A4.5 4.5 0 0 0 7 7.5c0 6 10 3 10 9A4.5 4.5 0 0 1 12.5 21h-1A4.5 4.5 0 0 1 7 17.5',
    check:'m5 12 4 4L19 6',
    info:'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20ZM12 11v6M12 7h.01',
    empty:'M4 5h16v14H4zM8 9h8M8 13h5',
    close:'M6 6l12 12M18 6 6 18',
    copy:'M8 8h12v12H8zM4 16H3V4h12v1'
  };

  function icon(name,{size=20,label='',className=''}={}){
    const path=paths[name]||paths.info;
    const a11y=label?`role="img" aria-label="${escapeHtml(label)}"`:'aria-hidden="true" focusable="false"';
    return `<svg class="cui-icon ${className}" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" ${a11y}><path d="${path}"></path></svg>`;
  }

  function escapeHtml(value){
    return String(value??'').replace(/[&<>"']/g,char=>({
      '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
    }[char]));
  }

  function action({id='',label,iconName='',variant='primary',className='',attributes=''}={}){
    const classes=['btn',variant==='secondary'?'ghost':'',variant==='danger'?'danger':'',className].filter(Boolean).join(' ');
    return `<button class="${classes}"${id?` id="${escapeHtml(id)}"`:''} type="button" ${attributes}>${iconName?icon(iconName,{size:17}):''}<span>${escapeHtml(label)}</span></button>`;
  }

  function status(text,tone='neutral'){
    return `<span class="pill ${tone}" role="status">${escapeHtml(text)}</span>`;
  }

  function permissionBanner({canWrite,moduleLabel='This area'}={}){
    if(canWrite)return '';
    return `<aside class="permission-banner" role="note">${icon('info',{size:19})}<div><b>Read-only access</b><p>${escapeHtml(moduleLabel)} is available to review. Ask an owner for write access to make changes.</p></div></aside>`;
  }

  function pageHeader({title,subtitle='',iconName='info',actions='',canWrite=true,moduleLabel='This area'}={}){
    return `<header class="cui-page-head"><div class="cui-page-title">${icon(iconName,{size:24})}<div><h1>${escapeHtml(title)}</h1>${subtitle?`<p>${escapeHtml(subtitle)}</p>`:''}</div></div>${actions?`<div class="cui-page-actions">${actions}</div>`:''}</header>${permissionBanner({canWrite,moduleLabel})}`;
  }

  function card({title='',description='',body='',className='',id=''}={}){
    return `<section class="card cui-card ${className}"${id?` id="${escapeHtml(id)}"`:''}>${title?`<div class="cui-card-head"><h2>${escapeHtml(title)}</h2>${description?`<p>${escapeHtml(description)}</p>`:''}</div>`:''}${body}</section>`;
  }

  function field({id,label,control='input',type='text',value='',placeholder='',options=[],required=false,hint='',attributes=''}={}){
    const labelHtml=`<label for="${escapeHtml(id)}">${escapeHtml(label)}${required?' <span aria-hidden="true">*</span><span class="sr-only"> (required)</span>':''}</label>`;
    let input;
    if(control==='select')input=`<select id="${escapeHtml(id)}" ${required?'required ':''}${attributes}>${options.map(option=>`<option value="${escapeHtml(option.value)}"${option.selected?' selected':''}>${escapeHtml(option.label)}</option>`).join('')}</select>`;
    else if(control==='textarea')input=`<textarea id="${escapeHtml(id)}" placeholder="${escapeHtml(placeholder)}" ${required?'required ':''}${attributes}>${escapeHtml(value)}</textarea>`;
    else input=`<input id="${escapeHtml(id)}" type="${escapeHtml(type)}" value="${escapeHtml(value)}" placeholder="${escapeHtml(placeholder)}" ${required?'required ':''}${attributes}>`;
    return `<div class="cui-field">${labelHtml}${input}${hint?`<p class="cui-field-hint" id="${escapeHtml(id)}-hint">${escapeHtml(hint)}</p>`:''}</div>`;
  }

  function emptyState({iconName='empty',title='Nothing here yet',body='',actionHtml=''}={}){
    return `<div class="empty cui-empty">${icon(iconName,{size:32})}<h2>${escapeHtml(title)}</h2>${body?`<p>${escapeHtml(body)}</p>`:''}${actionHtml?`<div class="cui-empty-action">${actionHtml}</div>`:''}</div>`;
  }

  function loadingState({title='Loading',iconName='info',body='Loading the latest information…'}={}){
    return `<section class="cui-route-state" aria-busy="true" aria-labelledby="route-loading-title">${pageHeader({title,subtitle:body,iconName})}<div class="card empty" role="status"><h2 id="route-loading-title">Loading…</h2><p class="muted small">Please wait while Frenly prepares this page.</p></div></section>`;
  }

  function errorState({title='Unable to load this page',message='Try again.',retryId='routeRetry'}={}){
    return `<section class="cui-route-state" aria-labelledby="route-error-title">${pageHeader({title,subtitle:'The latest information could not be loaded.',iconName:'info'})}<div class="card"><div class="err" role="alert"><h2 id="route-error-title">Something went wrong</h2><p>${escapeHtml(message)}</p></div><div style="margin-top:16px">${action({id:retryId,label:'Try again',iconName:'retention'})}</div></div></section>`;
  }

  function table({caption,headers,rows,className=''}={}){
    return `<div class="cui-table-wrap" role="region" aria-label="${escapeHtml(caption)}" tabindex="0"><table class="cui-table ${className}" data-responsive="true"><caption>${escapeHtml(caption)}</caption><thead><tr>${headers.map(header=>`<th scope="col">${escapeHtml(header)}</th>`).join('')}</tr></thead><tbody>${rows.map(row=>`<tr>${row.map((cell,index)=>`<td data-label="${escapeHtml(headers[index]||'')}">${cell}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
  }

  let generatedFieldId=0;
  function associateLabels(root){
    root.querySelectorAll('label:not([for])').forEach(label=>{
      let control=label.querySelector('input,select,textarea');
      if(!control){
        const next=label.nextElementSibling;
        control=next?.matches?.('input,select,textarea')?next:next?.querySelector?.('input,select,textarea');
      }
      if(!control)return;
      if(!control.id)control.id=`cui-field-${++generatedFieldId}`;
      label.htmlFor=control.id;
    });
  }

  function tableCaption(table){
    const card=table.closest('.card');
    const heading=card?.querySelector('h2,h3,.cui-card-head,b');
    const page=table.closest('main')?.querySelector('h1');
    return (heading?.textContent||page?.textContent||'Data table').trim();
  }

  function enhanceTables(root){
    root.querySelectorAll('table').forEach(table=>{
      table.classList.add('cui-table');
      const isComplex=!!table.querySelector('[colspan],[rowspan]');
      table.dataset.responsive=isComplex?'false':'true';
      let caption=table.querySelector(':scope > caption');
      if(!caption){caption=document.createElement('caption');caption.textContent=tableCaption(table);table.prepend(caption)}
      let head=table.querySelector(':scope > thead');
      const firstRow=table.querySelector('tr');
      if(!head&&firstRow?.querySelector('th')){
        head=document.createElement('thead');head.append(firstRow);table.insertBefore(head,table.querySelector('tbody'));
      }
      let body=table.querySelector(':scope > tbody');
      const looseRows=[...table.children].filter(child=>child.tagName==='TR');
      if(looseRows.length){
        if(!body){body=document.createElement('tbody');table.append(body)}
        looseRows.forEach(row=>body.append(row));
      }
      head?.querySelectorAll('th').forEach(th=>th.scope='col');
      const headers=[...(head?.querySelectorAll('th')||[])].map(th=>th.textContent.trim());
      table.querySelectorAll('tr').forEach(row=>{if(row.closest('thead'))return;[...row.children].forEach((cell,index)=>{
        if(cell.tagName==='TD'&&!cell.dataset.label)cell.dataset.label=headers[index]||'Details';
      })});
      if(!table.parentElement?.classList.contains('cui-table-wrap')){
        const wrap=document.createElement('div');wrap.className='cui-table-wrap';wrap.tabIndex=0;
        wrap.setAttribute('role','region');wrap.setAttribute('aria-label',caption.textContent.trim()||'Data table');
        table.parentNode.insertBefore(wrap,table);wrap.append(table);
      }
    });
  }

  function enhance(root){associateLabels(root);enhanceTables(root)}

  function mountMain(root){
    enhance(root);
    const observer=new MutationObserver(()=>enhance(root));
    observer.observe(root,{childList:true,subtree:true});
    return observer;
  }

  function focusRoute(root,{enhanceContent=true}={}){
    if(enhanceContent)enhance(root);
    const heading=root.querySelector('h1');
    const target=heading||root;
    if(!target)return;
    if(!target.id)target.id='route-title';
    target.tabIndex=-1;
    requestAnimationFrame(()=>target.focus({preventScroll:false}));
  }

  function announce(message,{assertive=false}={}){
    const target=document.getElementById(assertive?'appAlert':'appStatus');
    if(!target)return;
    target.textContent='';
    requestAnimationFrame(()=>{target.textContent=String(message??'')});
  }

  function activateDialog(dialog,{onClose,initialFocus='button,input,select,textarea,[href]'}={}){
    const returnFocus=document.activeElement;
    const focusable=()=>[...dialog.querySelectorAll('button:not([disabled]),[href],input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])')]
      .filter(element=>!element.hidden&&element.getClientRects().length);
    const keydown=event=>{
      if(event.key==='Escape'){event.preventDefault();onClose?.();return}
      if(event.key!=='Tab')return;
      const items=focusable();if(!items.length){event.preventDefault();dialog.focus();return}
      const first=items[0],last=items[items.length-1];
      if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus()}
      else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus()}
    };
    dialog.addEventListener('keydown',keydown);
    requestAnimationFrame(()=>{const target=dialog.querySelector(initialFocus)||focusable()[0]||dialog;target.focus()});
    return ()=>{dialog.removeEventListener('keydown',keydown);dialog.remove();if(returnFocus?.isConnected)returnFocus.focus()};
  }

  global.FrenlyCustomerUI=Object.freeze({
    icon,action,status,permissionBanner,pageHeader,card,field,emptyState,loadingState,errorState,table,
    associateLabels,enhanceTables,enhance,mountMain,focusRoute,announce,activateDialog
  });
})(window);
