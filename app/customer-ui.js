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
    /* V275: bottle keep is a bar-only module; a bottle needs a bottle, not a borrowed box. */
    bottle:'M10 2h4v3.6l2.4 3.6c.4.6.6 1.3.6 2V21a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V11.2c0-.7.2-1.4.6-2L10 5.6zM7 15h10',
    star:'m12 3 2.8 5.67 6.26.91-4.53 4.42 1.07 6.24L12 17.77 6.4 20.91l1.07-6.24-4.53-4.42 6.26-.91L12 3Z',
    /* v264: a real share glyph — the standard three linked nodes. 'export' was being used for
       the share button and read as "download", which is a different promise. 'chat' gives the
       messaging channels a speech bubble instead of a crowd of people. */
    share:'M18 8a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM6 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm12 7a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM8.6 13.5l6.8 3.9M15.4 6.6 8.6 10.5',
    chat:'M21 15a2 2 0 0 1-2 2H8l-5 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2Z',
    /* v195: the owner drew a star, a crown and a gem on the tier bar — a rung a customer can
       recognise before reading its name. Same 24-box, same stroke weight as every icon here. */
    crown:'M4 18h16M3 7l4.5 4L12 4l4.5 7L21 7l-2 9H5L3 7Z',
    diamond:'M6 3h12l3 6-9 12L3 9l3-6ZM3 9h18M9 3 6 9l6 12M15 3l3 6-6 12',
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
    insight:'M9 18h6M10 22h4M8.6 14.8A6 6 0 1 1 15.4 14.8C14.5 15.5 14 16.5 14 18h-4c0-1.5-.5-2.5-1.4-3.2ZM12 2v2M4.9 4.9l1.4 1.4M19.1 4.9l-1.4 1.4',
    empty:'M4 5h16v14H4zM8 9h8M8 13h5',
    close:'M6 6l12 12M18 6 6 18',
    copy:'M8 8h12v12H8zM4 16H3V4h12v1',
    scan:'M4 9V5a1 1 0 0 1 1-1h4M15 4h4a1 1 0 0 1 1 1v4M20 15v4a1 1 0 0 1-1 1h-4M9 20H5a1 1 0 0 1-1-1v-4M7 12h10',
    eye:'M2.5 12s3.5-6 9.5-6 9.5 6 9.5 6-3.5 6-9.5 6-9.5-6-9.5-6ZM12 15.25A3.25 3.25 0 1 0 12 8.75a3.25 3.25 0 0 0 0 6.5Z',
    eyeOff:'M3 3l18 18M10.6 6.12A10.8 10.8 0 0 1 12 6c6 0 9.5 6 9.5 6a17.4 17.4 0 0 1-2.1 2.7M6.2 6.2C3.77 7.9 2.5 12 2.5 12s3.5 6 9.5 6a9.9 9.9 0 0 0 3.2-.52M9.7 9.7a3.25 3.25 0 0 0 4.6 4.6',
    faceId:'M8 3H5a2 2 0 0 0-2 2v3M16 3h3a2 2 0 0 1 2 2v3M21 16v3a2 2 0 0 1-2 2h-3M8 21H5a2 2 0 0 1-2-2v-3M9 9h.01M15 9h.01M12 9v4h-1M8.5 16c1 .8 2.17 1.2 3.5 1.2s2.5-.4 3.5-1.2',
    edit:'M4 20h4L19 9l-4-4L4 16v4ZM13.5 6.5l4 4'
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

  function action({id='',label,iconName='',variant='primary',className='',attributes='',busy=false}={}){
    const classes=['btn',variant==='secondary'?'ghost':'',variant==='danger'?'danger':'',variant==='ghost'?'ghost':'',busy?'is-loading':'',className].filter(Boolean).join(' ');
    const busyAttrs=busy?' aria-busy="true" disabled':'';
    return `<button class="${classes}"${id?` id="${escapeHtml(id)}"`:''} type="button"${busyAttrs} ${attributes}>${busy?'<span class="cui-button-spinner" aria-hidden="true"></span>':(iconName?icon(iconName,{size:17}):'')}<span>${escapeHtml(label)}</span></button>`;
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

  function emptyState({iconName='empty',title='Nothing here yet',body='',actionHtml='',tone='neutral'}={}){
    return `<div class="empty cui-empty tone-${escapeHtml(tone)}">${icon(iconName,{size:32})}<h2>${escapeHtml(title)}</h2>${body?`<p>${escapeHtml(body)}</p>`:''}${actionHtml?`<div class="cui-empty-action">${actionHtml}</div>`:''}</div>`;
  }

  function skeletonLine(width='100%',className=''){
    return `<span class="cui-skeleton-line ${className}" style="--skel-w:${escapeHtml(width)}" aria-hidden="true"></span>`;
  }

  function skeletonCard({lines=3,className=''}={}){
    return `<div class="card cui-skeleton-card ${className}" aria-hidden="true">${Array.from({length:lines}).map((_,index)=>skeletonLine(index===0?'58%':index===lines-1?'74%':'100%')).join('')}</div>`;
  }

  function skeletonGrid({cards=4,lines=3,className=''}={}){
    return `<div class="cui-skeleton-grid ${className}" aria-hidden="true">${Array.from({length:cards}).map(()=>skeletonCard({lines})).join('')}</div>`;
  }

  function tableSkeleton({rows=5,columns=5}={}){
    return `<div class="cui-table-wrap cui-table-skeleton" role="status" aria-busy="true" aria-label="Loading rows"><table class="cui-table" data-responsive="false"><tbody>${Array.from({length:rows}).map(()=>`<tr>${Array.from({length:columns}).map((_,index)=>`<td>${skeletonLine(index===0?'72%':index===columns-1?'48%':'88%')}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
  }

  function chartSkeleton({title='Loading chart'}={}){
    return `<div class="card cui-chart-skeleton" role="status" aria-busy="true" aria-label="${escapeHtml(title)}"><div class="cui-chart-skeleton-head">${skeletonLine('42%')}${skeletonLine('68%','short')}</div><div class="cui-chart-placeholder"><span></span><span></span><span></span><span></span><span></span></div></div>`;
  }

  function formSkeleton({fields=4}={}){
    return `<div class="card cui-form-skeleton" role="status" aria-busy="true" aria-label="Loading form">${Array.from({length:fields}).map((_,index)=>`<div class="cui-form-skeleton-field">${skeletonLine(index%2?'34%':'28%','label')}${skeletonLine('100%','control')}</div>`).join('')}${skeletonLine('38%','button')}</div>`;
  }

  function loadingState({title='Loading',iconName='info',body='Loading the latest information…',variant='route'}={}){
    const skeleton=variant==='table'?tableSkeleton():variant==='chart'?chartSkeleton({title}):variant==='form'?formSkeleton():skeletonGrid({cards:variant==='compact'?2:4,lines:3});
    return `<section class="cui-route-state cui-fade-in" aria-busy="true" aria-labelledby="route-loading-title">${pageHeader({title,subtitle:body,iconName})}<div role="status" class="sr-only" id="route-loading-title">Loading ${escapeHtml(title)}</div>${skeleton}</section>`;
  }

  function errorState({title='Unable to load this page',message='Try again.',retryId='routeRetry'}={}){
    return `<section class="cui-route-state" aria-labelledby="route-error-title">${pageHeader({title,subtitle:'The latest information could not be loaded.',iconName:'info'})}<div class="card"><div class="err" role="alert"><h2 id="route-error-title">Something went wrong</h2><p>${escapeHtml(message)}</p></div><div style="margin-top:16px">${action({id:retryId,label:'Try again',iconName:'retention'})}</div></div></section>`;
  }

  function table({caption,headers,rows,className=''}={}){
    /* V298: a caller that passes no caption used to get `<caption></caption>` and
       `aria-label=""` — an empty element AND a table with no accessible name, the worst of both.
       Emit no caption at all in that case and let enhanceTables derive one from the surrounding
       card heading (it always leaves a non-empty name behind), and never let the scroll region's
       label collapse to nothing. */
    const captionTextV298=String(caption??'').trim();
    const regionLabelV298=captionTextV298||'Data table';
    return `<div class="cui-table-wrap" role="region" aria-label="${escapeHtml(regionLabelV298)}" tabindex="0"><table class="cui-table ${className}" data-responsive="true">${captionTextV298?`<caption>${escapeHtml(captionTextV298)}</caption>`:''}<thead><tr>${headers.map(header=>`<th scope="col">${escapeHtml(header)}</th>`).join('')}</tr></thead><tbody>${rows.map(row=>`<tr>${row.map((cell,index)=>`<td data-label="${escapeHtml(headers[index]||'')}">${cell}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
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
    /* V298: `b` is in this list because that is how a workspace card writes its title — but a
       `b` INSIDE a table is a cell, not a title. Staff performance was naming its table after the
       first staff member in it ("Owner Person"), which is both a useless accessible name and a
       repeat of text already in the grid. Skip anything that lives in a table and fall through to
       the page heading, which is what the caller meant all along. */
    const heading=[...(card?.querySelectorAll('h2,h3,.cui-card-head,b')||[])]
      .find(node=>!node.closest('table')&&node.textContent.trim());
    const page=table.closest('main')?.querySelector('h1');
    return (heading?.textContent||page?.textContent||'Data table').trim();
  }

  /* V298 (owner report 2026-08-13, from a live Business Insights screenshot: "Revenue by type"
     printed as the card heading and AGAIN as a smaller grey line right beneath it — same for
     "Reversal reconciliation", "Loyalty flow…" and "Liabilities…", and the same across the rest
     of the workspace). Mechanism: a workspace card is written as
     `<div class="card"><b>Revenue by type</b><table>…`, and enhanceTables below then synthesised
     a <caption> whose text tableCaption() had just COPIED off that very <b>. The duplicate was
     structural, not a typo at any one call site.

     A <caption> is the native accessible name of a table, so deleting it would trade a cosmetic
     bug for a real accessibility regression (screen-reader users would meet an unnamed grid).
     The name is therefore kept and hidden with the document's existing .sr-only utility: the
     title is visible exactly once (the heading) and announced exactly once (the caption).

     Hand-written captions are left visible unless they repeat a heading verbatim, because those
     carry information the heading does not — platform console prints "{count} archived" and
     "First five source rows" in a caption, and hiding those would delete facts from the page. */
  function captionRepeatsHeadingV298(table,text){
    const name=text.trim().toLowerCase();
    if(!name)return false;
    const scope=table.closest('.card,.platform-detail-section,section');
    if(!scope)return false;
    /* `b`/`strong` are in the list because that is how the workspace cards write their titles;
       anything inside a table is a cell, not a heading, so it can never be the visible title. */
    return [...scope.querySelectorAll('h1,h2,h3,h4,.cui-card-head,b,strong')]
      .some(node=>!node.closest('table')&&node.textContent.trim().toLowerCase()===name);
  }

  /* V298: the one place that decides whether a table's name is also shown. A caption we
     synthesised is a copy of an already-visible heading by construction, so it is always hidden;
     an authored one is hidden only when it repeats that heading word for word. Either way the
     table is left with a non-empty accessible name. .sr-only is only ever added, never removed,
     so this is idempotent under the MutationObservers that drive both callers. */
  function nameTableOnceV298(table,caption,derived){
    if(derived||!caption.textContent.trim())caption.textContent=tableCaption(table);
    if(derived||captionRepeatsHeadingV298(table,caption.textContent))caption.classList.add('sr-only');
  }

  /* The workspace runs the full enhancer (mountMain); the platform console does not — it writes
     its own finished markup and would otherwise keep the doubled titles the owner reported, on
     "Loss reasons", "Contacts", "Payment history", "Campaign history", "Explore demand",
     "Partner register", "Suppression instructions" and "Stripe price catalogue". This observer is
     the caption rule ALONE: it never touches classes, data-label, thead or the wrapper, so it
     cannot restyle a console table that was never built for the responsive card layout. */
  function dedupeTableCaptionsV298(root){
    root.querySelectorAll('caption').forEach(caption=>{
      const table=caption.parentElement;
      if(table?.tagName==='TABLE')nameTableOnceV298(table,caption,false);
    });
  }

  function observeTableCaptionsV298(root){
    dedupeTableCaptionsV298(root);
    const observer=new MutationObserver(()=>dedupeTableCaptionsV298(root));
    observer.observe(root,{childList:true,subtree:true});
    return observer;
  }

  function enhanceTables(root){
    root.querySelectorAll('table').forEach(table=>{
      table.classList.add('cui-table');
      const isComplex=!!table.querySelector('[colspan],[rowspan]');
      table.dataset.responsive=isComplex?'false':'true';
      let caption=table.querySelector(':scope > caption');
      const derivedCaptionV298=!caption;
      if(!caption){caption=document.createElement('caption');table.prepend(caption)}
      nameTableOnceV298(table,caption,derivedCaptionV298);
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
    requestAnimationFrame(()=>target.focus({preventScroll:true}));
  }

  const liveRegionState=new WeakMap();
  function announce(message,{assertive=false}={}){
    const target=document.getElementById(assertive?'appAlert':'appStatus');
    if(!target)return;
    const previous=liveRegionState.get(target);
    if(previous?.timer)clearTimeout(previous.timer);
    const generation=(previous?.generation||0)+1;
    liveRegionState.set(target,{generation,timer:null});
    target.textContent='';
    requestAnimationFrame(()=>{
      if(liveRegionState.get(target)?.generation!==generation)return;
      target.textContent=String(message??'');
      const timer=setTimeout(()=>{
        if(liveRegionState.get(target)?.generation!==generation)return;
        target.textContent='';liveRegionState.delete(target);
      },5000);
      liveRegionState.set(target,{generation,timer});
    });
  }

  let dialogHistoryId=0;
  /* v183: when one sheet opens another (offer → company details), the outgoing sheet must NOT
     unwind its history entry. history.back() is asynchronous, so the pop landed AFTER the
     incoming sheet had pushed its own entry and closed it again on arrival — the company sheet
     appeared to be unclickable. Closing with {handOffHistory:true} leaves the entry in place and
     the incoming sheet adopts it via inheritHistoryId, so one Back still closes exactly one. */
  function currentDialogHistoryId(){
    const id=Number(history.state?.cuiDialog||0);
    return Number.isInteger(id)&&id>0?id:0;
  }
  function activateDialog(dialog,{onClose,initialFocus='button,input,select,textarea,[href]',inheritHistoryId=0}={}){
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
    /* v177: on Android the hardware/gesture Back is what people reach for to dismiss a sheet.
       Without a history entry it exits the whole route instead. pushState keeps the SAME url, so
       hashchange — the only navigation signal the app router listens to — never fires. Back then
       pops our entry and closes the dialog through the identical path as Escape. */
    const inherited=Number(inheritHistoryId)>0&&currentDialogHistoryId()===Number(inheritHistoryId);
    const historyId=inherited?Number(inheritHistoryId):++dialogHistoryId;
    let closedByUs=false;
    const popstate=()=>{
      window.removeEventListener('popstate',popstate);
      if(closedByUs||!dialog.isConnected)return;
      onClose?.();
    };
    try{
      if(!inherited)history.pushState({...(history.state||{}),cuiDialog:historyId},'');
      window.addEventListener('popstate',popstate);
    }catch{}
    requestAnimationFrame(()=>{const target=dialog.querySelector(initialFocus)||focusable()[0]||dialog;target.focus()});
    return ({restoreFocus=true,handOffHistory=false}={})=>{
      dialog.removeEventListener('keydown',keydown);
      window.removeEventListener('popstate',popstate);
      /* Only unwind our own entry, and only once — a Back-press already consumed it. */
      if(handOffHistory)closedByUs=true;
      else if(!closedByUs&&history.state?.cuiDialog===historyId){closedByUs=true;try{history.back()}catch{}}
      dialog.remove();
      if(restoreFocus&&returnFocus?.isConnected)returnFocus.focus();
    };
  }

  function setButtonBusy(button,{busy=true,label='Working…'}={}){
    if(!button)return ()=>{};
    if(!button.dataset.cuiOriginalHtml)button.dataset.cuiOriginalHtml=button.innerHTML;
    if(!button.dataset.cuiOriginalLabel)button.dataset.cuiOriginalLabel=button.textContent||'';
    button.disabled=!!busy;
    button.setAttribute('aria-busy',busy?'true':'false');
    button.classList.toggle('is-loading',!!busy);
    if(busy)button.innerHTML=`<span class="cui-button-spinner" aria-hidden="true"></span><span>${escapeHtml(label)}</span>`;
    else {
      button.innerHTML=button.dataset.cuiOriginalHtml||escapeHtml(button.dataset.cuiOriginalLabel||'');
      button.removeAttribute('aria-busy');
      delete button.dataset.cuiOriginalHtml;
      delete button.dataset.cuiOriginalLabel;
    }
    return ()=>setButtonBusy(button,{busy:false});
  }

  global.FrenlyCustomerUI=Object.freeze({
    icon,action,status,permissionBanner,pageHeader,card,field,emptyState,loadingState,errorState,table,
    skeletonLine,skeletonCard,skeletonGrid,tableSkeleton,chartSkeleton,formSkeleton,setButtonBusy,
    associateLabels,enhanceTables,enhance,mountMain,focusRoute,announce,activateDialog,
    dedupeTableCaptionsV298,observeTableCaptionsV298,
    currentDialogHistoryId
  });
})(typeof window !== 'undefined' ? window : globalThis);
