import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const appIndexHtml=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');
const appBundle=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const app=(appIndexHtml+'\n'+appBundle);
const migration=readFileSync(new URL('../../db/migrations/20260729_nestly_v97_workspace_interface_localization.sql',import.meta.url),'utf8');

function expressionBetween(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing expression start: ${start}`);
  assert.ok(to>from,`missing expression end: ${end}`);
  return app.slice(from+start.length,to).trim().replace(/;$/,'');
}

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

function ordinaryStringsContainingInterpolation(source){
  let index=0;
  const hits=[];
  const lineAt=position=>source.slice(0,position).split('\n').length;
  const quoted=quote=>{
    const start=index++;
    let value='';
    while(index<source.length){
      const character=source[index++];
      if(character==='\\'){
        value+=character+(source[index++]||'');
        continue;
      }
      if(character===quote)break;
      value+=character;
    }
    if(value.includes('${'))hits.push({line:lineAt(start),value});
  };
  const regexLiteral=()=>{
    index++;
    let characterClass=false;
    while(index<source.length){
      const character=source[index++];
      if(character==='\\'){index++;continue}
      if(character==='[')characterClass=true;
      else if(character===']')characterClass=false;
      else if(character==='/'&&!characterClass){
        while(/[a-z]/i.test(source[index]||''))index++;
        return;
      }
    }
  };
  const comment=()=>{
    if(source[index+1]==='/'){
      index+=2;
      while(index<source.length&&source[index]!=='\n')index++;
      return true;
    }
    if(source[index+1]==='*'){
      index+=2;
      while(index<source.length&&!(source[index]==='*'&&source[index+1]==='/'))index++;
      index+=2;
      return true;
    }
    return false;
  };
  const template=()=>{
    index++;
    while(index<source.length){
      const character=source[index];
      if(character==='\\'){index+=2;continue}
      if(character==='`'){index++;return}
      if(character==='$'&&source[index+1]==='{'){
        index+=2;
        code(true);
        continue;
      }
      index++;
    }
  };
  const code=stopAtTemplateBrace=>{
    let depth=stopAtTemplateBrace?1:0;
    let canStartRegex=true;
    while(index<source.length){
      const character=source[index];
      if(/\s/.test(character)){index++;continue}
      if(character==='"'||character==="'"){quoted(character);canStartRegex=false;continue}
      if(character==='`'){template();canStartRegex=false;continue}
      if(character==='/'&&comment())continue;
      if(character==='/'&&canStartRegex){regexLiteral();canStartRegex=false;continue}
      if(character==='{'){depth++;index++;canStartRegex=true;continue}
      if(character==='}'){
        if(stopAtTemplateBrace&&--depth===0){index++;return}
        index++;canStartRegex=false;continue;
      }
      if(/[A-Za-z_$]/.test(character)){
        const start=index++;
        while(/[\w$]/.test(source[index]||''))index++;
        canStartRegex=/^(?:return|throw|case|delete|void|typeof|instanceof|in|of|new|yield|await)$/.test(source.slice(start,index));
        continue;
      }
      if(/[0-9]/.test(character)){
        index++;
        while(/[\w.]/.test(source[index]||''))index++;
        canStartRegex=false;
        continue;
      }
      if(character===')'||character===']'){index++;canStartRegex=false;continue}
      if(character==='+'||character==='-'){
        const next=source[index+1];
        index+=next===character?2:1;
        canStartRegex=next!==character;
        continue;
      }
      index++;
      canStartRegex=true;
    }
  };
  code(false);
  return hits;
}

function executableInlineScripts(html){
  return [...html.matchAll(/<script(?<attrs>[^>]*)>(?<source>[\s\S]*?)<\/script>/gi)]
    .filter(({groups})=>!/\bsrc\s*=/i.test(groups?.attrs||''))
    .filter(({groups})=>{
      const type=(groups?.attrs||'').match(/\btype\s*=\s*["']([^"']+)["']/i)?.[1]?.toLowerCase();
      return !type||type==='text/javascript'||type==='application/javascript';
    })
    .map(({groups})=>groups?.source||'');
}

const curatedCopy=Function(`"use strict";return (${expressionBetween(
  'const WORKSPACE_COPY_V97=',
  '\nconst WORKSPACE_GENERATED_COPY_V97',
)})`)();
const generatedCopy=JSON.parse(expressionBetween(
  'const WORKSPACE_GENERATED_COPY_V97=Object.freeze(',
  ');\nconst workspaceTextSourcesV97',
));
const templateCopy=Function(`"use strict";return (${expressionBetween(
  'const WORKSPACE_TEMPLATE_COPY_V97=',
  '\nconst WORKSPACE_INTERPOLATED_UI_INVENTORY_V97',
)})`)();
const interpolatedInventory=Function(`"use strict";return (${expressionBetween(
  'const WORKSPACE_INTERPOLATED_UI_INVENTORY_V97=',
  '\nconst WORKSPACE_INTERPOLATED_ATTRIBUTE_INVENTORY_V97',
)})`)();
const interpolatedAttributeInventory=Function(`"use strict";return (${expressionBetween(
  'const WORKSPACE_INTERPOLATED_ATTRIBUTE_INVENTORY_V97=',
  '\nconst workspaceTemplateTextV97',
)})`)();
const translated=(locale,source)=>curatedCopy[locale]?.[source]??generatedCopy[locale]?.[source]??source;
const templateText=(key,values,locale)=>{
  const template=templateCopy[key]?.[locale]??templateCopy[key]?.en??'';
  return template.replace(/\{([a-z][a-z0-9_]*)\}/gi,(_,name)=>String(values[name]??''));
};
const placeholders=value=>[...value.matchAll(/\{([a-z][a-z0-9_]*)\}/gi)].map(match=>match[1]).sort();

test('v97 workspace exposes and persists English, Chinese and Bahasa Melayu',()=>{
  assert.match(app,/WORKSPACE_LOCALES_V97=Object\.freeze\(\['en','zh-CN','ms'\]\)/);
  assert.match(app,/<option value="en"[^>]*>English<\/option>/);
  assert.match(app,/<option value="zh-CN"[^>]*>中文<\/option>/);
  assert.match(app,/<option value="ms"[^>]*>Bahasa Melayu<\/option>/);
  assert.match(app,/get_workspace_locale_preference_v97/);
  assert.match(app,/set_workspace_locale_preference_v97/);
  assert.match(migration,/locale in \('en','zh-CN','ms'\)/);
  assert.match(migration,/where public\.workspace_locale_preferences_v97\.version=p_expected_version/);
  assert.match(migration,/preferred_locale in \('en','zh-CN','ms'\)/);
  assert.match(migration,/coalesce\(p_locale,''\) not in \('en','zh-CN','ms'\)/);
  assert.match(migration,/to service_role/);
});

test('v97 catalog covers every signed-in workspace route plus dialogs, states and feedback',()=>{
  const required=[
    'Dashboard','Customers','Record sale','Appointments','Bookings','Waitlist','Sales',
    'Rewards & bring-backs','Referrals','Memberships','Gift cards','Reports',
    'Customer intelligence','Staff performance','Daily report','Expenses','P&L',
    'Inventory','Packages','Branches','Services','Settings','Get started',
    'Notifications','Stored value','Program Studio',
    'Loading…','No customers yet','Something went wrong. Please try again.',
    'Save','Cancel','Confirm','Try again','Appointment details','Unable to load details',
    'Confirm amendment','Booking rules saved','Branch settings','Additional access required',
  ];
  for(const locale of ['zh-CN','ms']){
    for(const source of required){
      const value=translated(locale,source);
      assert.ok(value&&value!==source,`${locale} must translate ${source}`);
    }
  }
  assert.match(app,/WORKSPACE_COPY_V97\[workspaceLocale\]\?\.\[source\]\?\?WORKSPACE_GENERATED_COPY_V97\[workspaceLocale\]\?\.\[source\]\?\?source/);
  assert.match(app,/data-workspace-i18n/);
  assert.match(app,/\.side,\.appbar,\.main,\[role="dialog"\],\[data-workspace-i18n\]/);
});

test('v97 generated catalog contains no prompt leakage or executable source fragments',()=>{
  const serialized=JSON.stringify(generatedCopy);
  for(const artifact of [
    'Business software interface text','业务软件界面文字','商业软件界面文字',
    '商务软件界面文字','商务软件界面文本','Teks antara muka perisian perniagaan',
    'rows.push','Number.isFinite','storedValuePage();','=>','||','&&','.dataset',
  ]) assert.doesNotMatch(serialized,new RegExp(artifact.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')),artifact);
  for(const locale of ['zh-CN','ms']){
    assert.equal(Object.keys(generatedCopy[locale]).length,1472,`${locale} valid visible-literal inventory changed without catalog review`);
  }
});

test('ordinary JavaScript strings in the application can never contain inert template interpolation',()=>{
  // The application's JavaScript now lives in the external bundle app/app.js
  // plus whatever small inline scripts remain in the shell markup. Audit both.
  const scripts=[...executableInlineScripts(appIndexHtml),appBundle];
  assert.ok(scripts.length>0,'application must expose executable JavaScript to audit');
  const hits=scripts.flatMap((source,scriptIndex)=>
    ordinaryStringsContainingInterpolation(source)
      .map(hit=>({...hit,script:scriptIndex+1})));
  assert.deepEqual(
    hits,
    [],
    'use a template literal or precompute localized HTML; ordinary strings render ${...} verbatim',
  );
});

test('v97 curated translations override generated values for critical labels',()=>{
  assert.equal(translated('zh-CN','Clear'),'清除');
  assert.equal(translated('ms','Clear'),'Kosongkan');
  assert.equal(translated('zh-CN','Record sale'),'记录销售');
  assert.equal(translated('ms','Record sale'),'Rekod jualan');
  assert.equal(translated('zh-CN','Business'),'企业');
  assert.equal(translated('ms','Business'),'Perniagaan');
});

test('v97 Malay domain glossary uses SaaS, capacity and campaign meanings',()=>{
  const cases=[
    ["When you're full",/kapasiti.*penuh/i,/kenyang/i],
    ['Self-funding by design: nothing pays out until the new customer has actually come in and spent above your floor. One reward per referred customer, ever.',/ambang/i,/lantai/i],
    ['"Record offers" logs each offer against the customer so the lift can be measured. To actually reach them, copy the contact list and message them on WhatsApp yourself. Held-back customers are never contacted.',/peningkatan kempen/i,/tingkatan|daya angkat/i],
    ['Win back customers slipping away — and prove the lift against a held-back control group.',/peningkatan kempen/i,/daya angkat|tingkatan/i],
    ['Stored value is not switched on for any customer here: nothing on this screen moves real money or can be used to pay. Every state below comes straight from the server.',/status/i,/negeri/i],
    ['Cutover',/pengaktifan/i,/potongan|pemotongan/i],
    ['Cutover makes stored value real for this business: customers can top up and spend actual money. It happens once, it cannot be undone from this screen, and it needs a super admin to designate this business first.',/pengaktifan/i,/potongan|pemotongan/i],
  ];
  for(const [source,required,forbidden] of cases){
    const value=translated('ms',source);
    assert.match(value,required,source);
    assert.doesNotMatch(value,forbidden,source);
  }
  for(const source of ['Lift emergency pause','Lift stored-value pause','Lift this pause']){
    assert.match(translated('ms',source),/Tamatkan jeda/);
    assert.doesNotMatch(translated('ms',source),/^Angkat/);
  }
});

test('v97 localization preserves merchant/customer records even when values collide with UI labels',()=>{
  const guard=section('function isWorkspaceDynamicNodeV97','function isWorkspaceTableDataNodeV97');
  const tableGuard=section('function isWorkspaceTableDataNodeV97','function localizeWorkspaceSubtreeV97');
  const localizer=section('function localizeWorkspaceSubtreeV97','function observeWorkspaceLocalizationV97');
  assert.match(localizer,/\.side,\.appbar,\.main,\[role="dialog"\],\[data-workspace-i18n\]/);
  assert.match(guard,/\.wallet-shell','\[data-merchant-content\]','\[data-workspace-template\]','\.notif-item/);
  assert.doesNotMatch(guard,/'td'|'\.checkout-catalogue-item'/);
  assert.match(tableGuard,/button,\.btn,\.pill,\[data-workspace-i18n\]/);
  assert.match(localizer,/'placeholder','title','aria-label','data-label'/);
  assert.match(localizer,/isWorkspaceTableDataNodeV97\(node\.parentElement\)/);
  assert.match(guard,/element instanceof HTMLOptionElement/);
  assert.match(app,/querySelector\('\.cui-page-title h1'\)\?\.setAttribute\('data-merchant-content',''\)/);
  assert.match(app,/<h1 data-merchant-content>\$\{esc\(staffName\)\}<\/h1>/);
  assert.match(app,/id="appointmentDetailTitle" data-merchant-content/);
  assert.match(app,/<dd data-merchant-content>\$\{esc\(service\.name\|\|'General visit'\)\}<\/dd>/);
  assert.match(app,/<p data-merchant-content>\$\{esc\(client\.notes\|\|'None'\)\}<\/p>/);
  assert.match(app,/<b data-merchant-content>\$\{esc\(p\.name\)\}<\/b>/);
  assert.match(app,/<b data-merchant-content[^>]*>\$\{esc\(S\.biz\.name\)\}<\/b>/);
  assert.match(app,/<b data-merchant-content>\$\{esc\(w\.name\)\}<\/b>/);
  assert.match(app,/workspaceTextSourcesV97=new WeakMap/);

  const collisions=[
    ['customer','Home'],['service','Business'],['product','Clear'],
    ['package','Record sale'],['staff','Quick earn'],['note','Appointments'],
  ];
  for(const [kind,value] of collisions){
    assert.notEqual(translated('zh-CN',value),value,`${kind} collision fixture must be a real UI key`);
    assert.notEqual(translated('ms',value),value,`${kind} collision fixture must be a real UI key`);
  }
});

test('v97 named templates are an exact reviewed inventory with locale and placeholder parity',()=>{
  const keys=Object.keys(templateCopy);
  /* 116 -> 121: V217 added selectedStaffFree, selectedStaffFreeFairer and recentInWindow for the
     rewritten availability panel; V215 added welcomeOfferGiven; V225 added accountMenuForBusiness
     when the business name left the top bar and the account button needed its own name. Each was
     reviewed with all three locales and matching placeholders, which the assertions below check. */
  /* 121 -> 124: v150 (deb980e) deleted dashboardSummary's only render path and V217 (6d589bf)
     superseded recentAppointments with recentInWindow — both dead entries removed; v281 adds
     performancePeriodRange, pointCostDerived, parkExpiryPreview(+Tier) and parkKeptUntil,
     bringing the V266/V262/V278 interpolated workspace copy into the reviewed inventory,
     plus sortByAscending/sortByDescending for the v267 customer-360 sort control and
     bottlePercentLeft for the v275 fill bar and the three v269 booking-request
     button strings. */
  /* 130 -> 131: V295 adds scheduleHeadingDay — the Dashboard schedule card now names the day it
     is showing ("Schedule · 13 Aug 2026"), which is interpolated workspace copy and so joins the
     reviewed inventory with all three locales and matching placeholders. */
  /* 131 -> 132: V330 adds calendarPendingRequest — the Day-view calendar tile for a not-yet-
     confirmed booking request (owner: "click into it > pop up approve/reject or change timing/
     staff", "colour differentiation from actual confirmed appointment") carries its own dynamic
     aria-label, reviewed with all three locales and matching placeholders like calendarAppointment. */
  /* 132 -> 133: V362 adds bringbackVoucherGiven — the till's bring-back voucher toast names the
     item handed over, exactly as welcomeOfferGiven does for the welcome gift, so it is reviewed
     interpolated copy rather than a raw template literal. Three locales, one {item} placeholder. */
  /* 133 -> 133 (V364/V365, net zero): the four growPublished* entries retired with the "How the
     programme fits together" block are replaced by the four tier-benefit till toasts.
     133 -> 135: V367 adds tierBenefitBirthdayOnly and tierBenefitBirthdayUnknown — the two
     refusals a birthday-month benefit can produce at the counter, each naming the benefit, with
     all three locales and one {item} placeholder. */
  /* 135 -> 134: V375 retires classicEligibleEarning with the fixed-redeem panel that was its only
     render path (owner, photo 3: "i don't want credit feature") — the same rule V364 applied to
     the growPublished* keys when their block was removed. */
  /* 134 -> 135: V385 adds explainHelpDotV385, the label on the "?" affordance the owner asked
     for on the Blocked time card (photo 4) — one {topic} placeholder, all three locales. */
  assert.equal(keys.length,135,'mixed-interface interpolation inventory changed without review');
  assert.deepEqual([...interpolatedInventory].sort(),[...keys].sort());
  assert.equal(new Set(interpolatedInventory).size,interpolatedInventory.length);
  for(const key of interpolatedInventory){
    const copy=templateCopy[key];
    assert.deepEqual(Object.keys(copy).sort(),['en','ms','zh-CN']);
    const expected=placeholders(copy.en);
    assert.deepEqual(placeholders(copy['zh-CN']),expected,`${key} Chinese placeholders`);
    assert.deepEqual(placeholders(copy.ms),expected,`${key} Malay placeholders`);
    const callSiteCount=app.split(`'${key}'`).length-1;
    assert.ok(callSiteCount>=2,`${key} must be in the inventory and at least one render path`);
  }
  assert.match(app,/workspaceTemplateValuesV97=new WeakMap/);
  assert.match(app,/data-workspace-value="\$\{esc\(name\)\}" data-merchant-content/);
  assert.match(app,/localizeWorkspaceTemplateV97\(template\)/);
});

test('v101 localization observer cannot recursively rewrite its own template children',()=>{
  const templateLocalizer=section(
    'function localizeWorkspaceTemplateV97',
    'function localizeWorkspaceTemplateAttributesV97',
  );
  const observer=section(
    'function observeWorkspaceLocalizationV97',
    'async function loadWorkspaceLocaleV97',
  );
  assert.match(templateLocalizer,/const localizedHtml=workspaceTemplateInnerHtmlV97/);
  assert.match(templateLocalizer,/if\(element\.innerHTML!==localizedHtml\)element\.innerHTML=localizedHtml/);
  assert.match(observer,/node\.nodeType!==Node\.ELEMENT_NODE[\s\S]*element\.closest\?\.\('\[data-workspace-template\],\[data-merchant-content\]'\)\)continue/);
  assert.match(observer,/node\.nodeType===Node\.ELEMENT_NODE[\s\S]*!element\.matches\?\.\('\[data-workspace-template\]'\)\)continue/);
  assert.ok(
    observer.indexOf('continue;')<observer.indexOf('localizeWorkspaceSubtreeV97(element)'),
    'self-generated template children must be rejected before the localizer runs',
  );
});

test('v97 every runtime template executes arbitrary values without translating, dropping or merging them',()=>{
  for(const key of interpolatedInventory){
    const names=placeholders(templateCopy[key].en);
    const values=Object.fromEntries(names.map((name,index)=>[name,`__${key}_${name}_${index}__<&`]));
    for(const locale of ['en','zh-CN','ms']){
      const output=templateText(key,values,locale);
      assert.doesNotMatch(output,/\{[a-z][a-z0-9_]*\}/i,`${key}/${locale} unresolved placeholder`);
      for(const value of Object.values(values)){
        assert.equal(output.split(value).length-1,1,`${key}/${locale} must preserve ${value} exactly once`);
      }
    }
  }
});

test('v97 exhaustively classifies signed-in workspace interpolated accessibility attributes',()=>{
  const signedInWorkspace=[
    section('function businessWorkspaceSwitchHtml','function renderNoCustomerDestination'),
    section('function parseDelimited','async function platformPage'),
  ].join('\n');
  const rawDynamicAttributes=[...signedInWorkspace.matchAll(
    /<[^>]*\b(?:aria-label|title|placeholder)="[^"\n]*\$\{[^"\n]*"[^>]*>/g,
  )].map(match=>match[0]);
  assert.ok(rawDynamicAttributes.length>0,'audit must exercise remaining controlled/data attributes');
  for(const tag of rawDynamicAttributes){
    assert.match(
      tag,
      /\b(?:data-workspace-i18n|data-merchant-content)\b/,
      `unclassified dynamic workspace accessibility attribute: ${tag}`,
    );
  }
  assert.doesNotMatch(
    signedInWorkspace,
    /(?:setAttribute\(\s*['"](?:aria-label|title|placeholder)['"]|(?:\.ariaLabel|\.title|\.placeholder)\s*=)[^\n;]*\$\{/,
    'programmatic interpolated accessibility attributes must use the named template mechanism',
  );

  const expected=[
    'switchOtherWorkspace','switchOtherWorkspaces','notificationsUnread',
    'phoneKeyDelete','phoneKeyClear','phoneKeyDigit','openCustomer','removeItem',
    'adjustLoyalty','viewAppointmentDetails','amendAppointment','viewAppointmentAgenda',
    'calendarAppointment','calendarPendingRequest','bookAppointmentSlot','removeFromWaitlist','joinedAt',
    'viewDashboardMetricDetails',
    /* V385: the "?" help affordance (owner, photo 4) — its label names the thing it explains,
       so it interpolates and goes through the named template like every other one here. */
    'explainHelpDotV385',
  ];
  assert.deepEqual([...interpolatedAttributeInventory].sort(),expected.sort());
  assert.equal(new Set(interpolatedAttributeInventory).size,interpolatedAttributeInventory.length);
  for(const key of interpolatedAttributeInventory){
    assert.match(
      signedInWorkspace,
      new RegExp(`workspaceTemplateAttributeV97\\([\\s\\S]{0,180}?'${key}'`),
      `${key} must have a signed-in workspace attribute call site`,
    );
    const names=placeholders(templateCopy[key].en);
    const values=Object.fromEntries(names.map((name,index)=>[
      name,
      `__attribute_${key}_${name}_${index}__<&"'`,
    ]));
    const decoded=JSON.parse(decodeURIComponent(encodeURIComponent(JSON.stringify(values))));
    assert.deepEqual(decoded,values,`${key} attribute data round-trip`);
    for(const locale of ['en','zh-CN','ms']){
      const output=templateText(key,decoded,locale);
      assert.doesNotMatch(output,/\{[a-z][a-z0-9_]*\}/i,`${key}/${locale} unresolved attribute placeholder`);
      for(const value of Object.values(values)){
        assert.equal(output.split(value).length-1,1,`${key}/${locale} must preserve ${value} exactly once`);
      }
    }
  }

  const attributeRuntime=section(
    'const WORKSPACE_TEMPLATE_ATTRIBUTES_V97',
    'function isWorkspaceDynamicNodeV97',
  );
  assert.match(attributeRuntime,/data-workspace-\$\{attribute\}-template/);
  assert.match(attributeRuntime,/encodeURIComponent\(JSON\.stringify\(values\)\)/);
  assert.match(attributeRuntime,/JSON\.parse\(decodeURIComponent/);
  assert.match(attributeRuntime,/element\.setAttribute\(attribute,workspaceTemplateTextV97\(key,values\)\)/);
  const localizer=section('function localizeWorkspaceSubtreeV97','function observeWorkspaceLocalizationV97');
  assert.ok(
    localizer.indexOf('localizeWorkspaceTemplateAttributesV97(element)')
      <localizer.indexOf('if(isWorkspaceDynamicNodeV97(element))continue'),
    'excluded merchant/customer nodes must receive their localized template attributes first',
  );
  assert.match(localizer,/element\.hasAttribute\(`data-workspace-\$\{attribute\}-template`\)/);
});

test('v97 workspace has no unreviewed interpolated toast, announcement or textContent runtime copy',()=>{
  const workspace=section('function parseDelimited','async function platformPage');
  assert.doesNotMatch(workspace,/(?:toast|CUI\.announce)\(\s*`[^`]*\$\{/);
  assert.doesNotMatch(workspace,/\.textContent\s*=\s*`[^`]*\$\{/);
  assert.match(workspace,/workspaceTemplateTextV97\('itemSelected'/);
  assert.match(workspace,/workspaceTemplateHtmlV97\(\['wizardStepWho'/);
  assert.match(workspace,/workspaceTemplateHtmlV97\('preparingExport'/);
  assert.match(workspace,/workspaceTemplateHtmlV97\(pending\.length===1\?'imageCleanupPending':'imageCleanupsPending'/);
});

test('v97 dynamic count, page, amount, status, import, QR and billing copy localizes without changing data',()=>{
  const fixtures={
    business:'Home',staff:'Quick earn',item:'Clear',code:'NEST-Home-001',
    error:'Home / Clear / 失败 <do not alter>',amount:'SGD 1,234.56',
    date:'2026-07-29 18:45',from:'2026-07-01',to:'2026-07-31',
  };
  for(const locale of ['zh-CN','ms']){
    const rendered=[
      templateText('customerPagination',{total:9999,page:12,pages:40},locale),
      templateText('completedTransactions',{count:2},locale),
      templateText('scopePeriod',{branch:'Business',from:fixtures.from,to:fixtures.to},locale),
      templateText('giftCardLoaded',{amount:fixtures.amount},locale),
      templateText('requestStatus',{status:'completed'},locale),
      templateText('itemAdded',{item:fixtures.item},locale),
      templateText('bookedWith',{staff:fixtures.staff},locale),
      templateText('measurementStartedEnds',{ends:fixtures.date},locale),
      templateText('receiptConfirmationsRecorded',{count:2},locale),
      templateText('receiptConfirmationsFailed',{count:2},locale),
      templateText('exposureRetryChannelLocked',{channel:'whatsapp'},locale),
      templateText('exposureRetryMixedChannels',{},locale),
      templateText('inviteCreated',{code:fixtures.code},locale),
      templateText('importPartial',{count:7,error:fixtures.error},locale),
      templateText('qrReadyExpiresQrsRevoked',{expires:fixtures.date,count:4},locale),
      templateText('billingBaseExtraMany',{base:'SGD 99.00',included:3,extra:2,seat:'SGD 15.00',total:'SGD 129.00'},locale),
    ].join('\n');
    for(const value of Object.values(fixtures))assert.ok(rendered.includes(value),`${locale} preserves ${value}`);
    assert.doesNotMatch(rendered,/How Home is doing|customers · page|completed transactions|loaded onto account|Booked with|older QRs revoked|logins included/);
  }
  assert.equal(templateText('completedTransaction',{count:1},'en'),'1 completed transaction');
  assert.equal(templateText('completedTransactions',{count:2},'en'),'2 completed transactions');
  assert.equal(templateText('importBooking',{count:1},'en'),'Import 1 booking');
  assert.equal(templateText('importBookings',{count:2},'en'),'Import 2 bookings');
  assert.equal(templateText('activeQrRevoked',{count:1},'en'),'1 active QR revoked.');
  assert.equal(templateText('activeQrsRevoked',{count:2},'en'),'2 active QRs revoked.');
  assert.equal(templateText('measurementStarted',{},'en'),'Measurement started');
  assert.equal(templateText('measurementStartedEnds',{ends:fixtures.date},'en'),`Measurement started · ends ${fixtures.date}`);
  assert.equal(templateText('receiptConfirmationRecorded',{count:1},'en'),'1 manual receipt confirmation recorded');
  assert.equal(templateText('receiptConfirmationsRecorded',{count:2},'en'),'2 manual receipt confirmations recorded');
  assert.equal(templateText('receiptConfirmationFailed',{count:1},'en'),'1 confirmation could not be recorded. Retry the same selected customer.');
  assert.equal(templateText('receiptConfirmationsFailed',{count:2},'en'),'2 confirmations could not be recorded. Retry the same selected customers.');
  assert.equal(templateText('exposureRetryChannelLocked',{channel:'whatsapp'},'en'),'This retry is locked to whatsapp because that is the channel you originally confirmed. Choose that channel, or close and start a separate new attempt.');
});

test('v97 checkout and responsive tables localize interface parts while preserving row data',()=>{
  const checkout=section('async function loadCheckoutCatalogue','loadCheckoutCatalogue();');
  const appointments=section('async function loadList()','function layoutCalendarDay');
  assert.match(checkout,/<b data-merchant-content>\$\{esc\(item\.name\)\}<\/b>/);
  assert.match(checkout,/<span data-workspace-i18n>\$\{type\}<\/span> · <span data-merchant-content>\$\{money/);
  assert.match(checkout,/<span data-workspace-i18n>\$\{esc\(status\)\}<\/span>/);
  assert.match(checkout,/workspaceTemplateTextV97\(!enabled\?'catalogueEnabled':'catalogueDisabled'\)/);
  assert.match(appointments,/data-label="Date & time"/);
  assert.match(appointments,/<span data-workspace-i18n>min<\/span>/);
  /* V288 (audit A2 LOW 23): RETARGETED, not deleted. `a.status.replace('_',' ')` put the raw
     database value on screen ("no show", "booked"); statusLabelV288 is the one friendly-label
     table, and its output is still marked for the workspace localizer. */
  assert.match(appointments,/<span class="pill \$\{[^}]+\}"><span data-workspace-i18n>\$\{esc\(statusLabelV288\(a\.status\)\)\}<\/span><\/span>/);
  assert.match(appointments,/>Details<\/button>/);
  assert.match(appointments,/>Amend<\/button>/);
  for(const source of ['booked','completed','cancelled','no show','Available in Record sale','Hidden from Record sale','Not offered at this branch']){
    assert.notEqual(translated('zh-CN',source),source,`Chinese ${source}`);
    assert.notEqual(translated('ms',source),source,`Malay ${source}`);
  }
});

test('v97 known mixed English interpolation regressions are absent from render paths',()=>{
  for(const source of [
    '${total} customers · page ${clientPage+1} of ${pages}',
    'Adjusted — new balance ${data} pts (audited)',
    'Request ${data.status}',
    'Imported ${data.inserted} bookings — review them above as pending',
    '${n} new return${n===1?\'\':\'s\'} recorded',
    '${money(data.loaded_cents)} loaded onto account 🎉',
    'Session used — ${data} left. Visit counted for retention ✓',
    'Catalogue-first checkout ${!enabled?\'enabled\':\'disabled\'}',
    'Invite created: ${data.code} — copied',
    'The fixed snapshot expected ${total} records but returned ${customers.length}.',
    'An active QR already exists${activeExpiry?',
    '${button.textContent.trim()} selected',
    'Step ${state.step+1} of 4 — ${PB_STEPS[state.step]}',
    'Measurement started${data?.measurement_ends_at?',
    '${confirmed} manual receipt confirmation${confirmed===1?',
    'Showing ${available.length} eligible staff member',
    '${person.recent_appointments} recent',
    'Reversal of ${esc(x.original_sale_id',
    'Used session → reversed by ${esc(x.reversal_sale_id',
    'Preparing ${Math.min(customers.length',
    'previous image cleanup ${pending.length===1?',
    'Enter a positive ${unit} cost',
  ]) assert.ok(!app.includes(source),`raw mixed interpolation remains: ${source}`);
});

test('v97 package and sales tables split interface prose from customer, package and audit identifiers',()=>{
  const sales=section('async function salesPage','async function servicesPage');
  const packages=section('async function packagesPage','async function branchesPage');
  assert.match(sales,/data-workspace-i18n>Package session · no payment refund<\/span>/);
  assert.match(packages,/workspaceTemplateHtmlV97\('reversalOf',\{id:x\.original_sale_id\|\|''\}\)/);
  assert.match(packages,/workspaceTemplateHtmlV97\('usedSessionReversedBy',\{id:x\.reversal_sale_id\}\)/);
  assert.match(packages,/<span data-workspace-i18n>Used session<\/span>/);
  // Reworded to plainer English ("Session added back") in line with the low-literacy-first
  // UX direction. The pill still exists and is still a translated string; only the wording moved.
  assert.match(packages,/<span class="pill ok">Session added back · no refund<\/span>/);
  assert.match(packages,/<span class="pill new">session used<\/span>/);
  assert.match(packages,/>Undo session use<\/button>/);
  assert.match(packages,/<td>\$\{esc\(x\.customer_name\|\|'Customer'\)\}<\/td>/);
  assert.match(app,/isWorkspaceTableDataNodeV97/);
});

test('v97 public application security and password controls follow its locale while customer auth stays English',()=>{
  const challenge=section('const authSecurityCopy','/* Supabase Auth has CAPTCHA protection enabled');
  const application=section('function renderBusinessApplication','async function renderApprovedBusinessInviteSignup');
  const invite=section('async function renderApprovedBusinessInviteSignup','async function renderApprovedBusinessActivation');
  const customer=section('function passwordControlHtml','function normalizeSingaporeCustomerPhone');
  for(const phrase of [
    'Memuatkan semakan keselamatan…','Cuba semakan keselamatan lagi',
    'Semakan keselamatan selesai.','Tunjukkan kata laluan','Sembunyikan kata laluan',
    'Log masuk dengan Face ID, Touch ID atau kunci laluan',
    '正在加载安全验证…','显示密码','隐藏密码',
  ]) assert.ok(challenge.includes(phrase),phrase);
  assert.match(application,/authChallengeHtml\(locale\)/);
  assert.match(application,/action:'frenly_auth',locale/);
  assert.match(invite,/passwordControlHtml\('approvedOwnerPassword',\{autocomplete:'new-password',locale\}\)/);
  assert.match(invite,/authChallengeHtml\(locale\)/);
  assert.match(invite,/action:'frenly_auth',locale/);
  assert.match(customer,/locale='en'/);
  assert.match(customer,/data-password-show-label/);
  assert.match(customer,/data-password-hide-label/);
  for(const customerCall of [
    "passwordControlHtml('customerPassword'",
    "passwordControlHtml('customerSignupPassword'",
    'authChallengeHtml()',
  ]) assert.ok(app.includes(customerCall),`customer English default remains: ${customerCall}`);
});

test('v97 Quick Earn collision markers preserve customer, phone and single-branch values',()=>{
  const till=section('async function tillPage','async function salesPage');
  assert.match(till,/<div data-merchant-content style="font-size:1\.9rem[^>]*>\$\{esc\(cust\.full_name\)\}<\/div>/);
  assert.match(till,/<p class="muted small" data-merchant-content>\$\{esc\(cust\.phone\|\|''\)\}<\/p>/);
  assert.match(till,/<span data-merchant-content>\$\{esc\(accessibleTillBranches\[0\]\.name\)\}<\/span>/);
  /* V373 compressed the composer's customer block into one line; the marker that keeps a
     customer's own name out of the translation pass moved with it. */
  assert.match(till,/<b class="till-head-name-v373" data-merchant-content>\$\{esc\(cust\.full_name\)\}<\/b>/);
  assert.match(till,/<span data-merchant-content>\$\{esc\(notFoundPhone\|\|phone\)\}<\/span>/);
});

test('v97 customer, login, recovery and public portal shells explicitly restore English',()=>{
  for(const name of [
    'renderCustomerRegistration','renderCustomerShell','renderCustomerWalletUnavailable',
    'renderCustomerWalletRetry','renderCustomerFirstProgrammeQuest',
    'renderPersonaResolutionUnavailable','renderAuth','renderPasswordUpdate',
    'renderRecoveryInvalid','renderPortal',
  ]){
    assert.match(app,new RegExp(`(?:async )?function ${name.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}[\\s\\S]{0,300}?document\\?\\.documentElement\\?\\.setAttribute\\('lang','en'\\)`),name);
  }
});

test('v293 customer portal follows the stored profile language without a separate locale RPC',()=>{
  const wallet=section('async function renderCustomerWallet','function renderCustomerNotificationPreferences');
  assert.doesNotMatch(app,/data-customer-locale=/);
  assert.doesNotMatch(app,/customer_get_locale_preference_v95/);
  assert.doesNotMatch(app,/customer_set_locale_preference_v95/);
  // v293: the wallet copy tables are trilingual and merchant programme copy is
  // requested in the member's language where the merchant published it (en/zh-CN).
  assert.match(section('const CUSTOMER_COPY','const CUSTOMER_PRIMARY_NAV'),/'zh-CN'\s*:\s*Object\.freeze/);
  assert.match(wallet,/businessId\?sb\.rpc\('customer_get_business_presentation_v95',\{p_business:businessId,p_branch:null,p_locale:merchantCopyLocale\(\)\}\)/);
  assert.match(app,/id="customerProfileLanguage"/);
  assert.match(app,/p_preferred_language:language/);
});

test('v97 merchant programme editor is canonical and keeps v96 media intact',()=>{
  const editor=section('async function loadCustomerProgrammePresentationEditorV95','async function settingsPage');
  assert.doesNotMatch(editor,/programmeNameZh|programmeTaglineZh|programmeDescriptionZh|programmeImageAltZh/);
  assert.doesNotMatch(editor,/Save bilingual overview|locale:'zh-CN'/);
  assert.match(editor,/p_locale:'en'/);
  assert.match(editor,/p_alt_zh_cn:null/);
  assert.match(app,/function customerProgrammeGridMarkupV96/);
  assert.match(app,/function customerProgrammeTileLogoV96/);
  assert.match(app,/customerMediaUrlV95\(business\?\.logo_url\)/);
});
