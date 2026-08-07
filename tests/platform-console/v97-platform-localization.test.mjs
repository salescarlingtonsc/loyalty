import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,Intl,Date,Map,Set,Proxy,Reflect};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
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

function mixedTemplateUiSegments(source){
  let index=0;
  const templates=[];
  const lineAt=position=>source.slice(0,position).split('\n').length;
  const quoted=quote=>{
    index++;
    while(index<source.length){
      const character=source[index++];
      if(character==='\\'){index++;continue}
      if(character===quote)return;
    }
  };
  const comment=()=>{
    if(source[index+1]==='/'){index+=2;while(index<source.length&&source[index]!=='\n')index++;return true}
    if(source[index+1]==='*'){index+=2;while(index<source.length&&!(source[index]==='*'&&source[index+1]==='/'))index++;index+=2;return true}
    return false;
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
  const template=()=>{
    const start=index++;
    let reconstructed='';
    while(index<source.length){
      const character=source[index];
      if(character==='\\'){reconstructed+=source.slice(index,index+2);index+=2;continue}
      if(character==='`'){index++;templates.push({line:lineAt(start),text:reconstructed});return}
      if(character==='$'&&source[index+1]==='{'){
        reconstructed+='§';index+=2;code(true);continue;
      }
      reconstructed+=character;index++;
    }
  };
  const code=stopAtTemplateBrace=>{
    let depth=stopAtTemplateBrace?1:0;
    let canStartRegex=true;
    while(index<source.length){
      const character=source[index];
      if(/\s/.test(character)){index++;continue}
      if(character==='"'||character==="'"){quoted(character);continue}
      if(character==='`'){template();continue}
      if(character==='/'&&comment())continue;
      if(character==='/'&&canStartRegex){regexLiteral();canStartRegex=false;continue}
      if(character==='{'){depth++;index++;canStartRegex=true;continue}
      if(character==='}'){
        index++;
        if(stopAtTemplateBrace&&--depth===0)return;
        canStartRegex=false;
        continue;
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
      index++;canStartRegex=true;
    }
  };
  code(false);
  const candidates=[];
  for(const templateLiteral of templates){
    if(!templateLiteral.text.includes('§'))continue;
    const segments=[];
    if(templateLiteral.text.includes('<')){
      segments.push(...[...templateLiteral.text.matchAll(/>([^<]+)</g)].map(match=>match[1]));
      segments.push(...[...templateLiteral.text.matchAll(/\b(?:aria-label|title|placeholder)="([^"]*§[^"]*)"/g)].map(match=>match[1]));
    }else segments.push(templateLiteral.text);
    for(const segment of segments){
      const normalized=segment.replace(/\s+/g,' ').trim();
      if(normalized.includes('§')&&/[A-Za-z]{2,}/.test(normalized))candidates.push({line:templateLiteral.line,text:normalized});
    }
  }
  return candidates;
}

test('platform console exposes explicit English, Chinese and Malay interface copy',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('zh-CN');
  assert.equal(api.platformText('Overview'),'概览');
  assert.equal(api.platformText('Commission payable'),'应付佣金');
  assert.equal(api.platformText('New & unassigned'),'新客户与未分配');
  api.setPlatformLocaleForTest('ms');
  assert.equal(api.platformText('Overview'),'Ringkasan');
  assert.equal(api.platformText('Commission payable'),'Komisen perlu dibayar');
  assert.equal(api.platformText('New & unassigned'),'Baharu & belum ditugaskan');
  api.setPlatformLocaleForTest('unsupported');
  assert.equal(api.platformText('Overview'),'Overview');
});

test('localized CUI translates interface metadata but never table data rows',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('zh-CN');
  const captured={};
  const CUI={
    table:options=>(captured.table=options,'table'),
    pageHeader:options=>(captured.pageHeader=options,'header')
  };
  const localized=api.localizedPlatformCUI(CUI);
  localized.table({
    caption:'Platform firm directory',
    headers:['Firm','Billing'],
    rows:[
      ['Billing','Commission payable'],
      ['Home','Business'],
      ['Clear','Overview']
    ]
  });
  localized.pageHeader({title:'Platform overview',subtitle:'Please try again.'});
  assert.deepEqual(captured.table.headers,['企业','账单']);
  assert.equal(captured.table.caption,'平台企业目录');
  assert.deepEqual(captured.table.rows,[
    ['Billing','Commission payable'],
    ['Home','Business'],
    ['Clear','Overview']
  ]);
  assert.equal(captured.pageHeader.title,'平台概览');
  assert.equal(captured.pageHeader.subtitle,'请重试。');
});

test('platform route loads and saves the v97 preference before rendering localized access',async()=>{
  const source=await read('app/platform-console.js');
  const render=source.slice(source.indexOf('async function render({'),source.indexOf('globalObject.NestlyPlatformConsole'));
  assert.match(source,/PLATFORM_LOCALES=Object\.freeze\(\['en','zh-CN','ms'\]\)/);
  assert.match(render,/await loadPlatformLocale\(sb\)/);
  assert.ok(render.indexOf('await loadPlatformLocale(sb)')<render.indexOf("platform_list_my_access_v89"));
  assert.match(render,/set_workspace_locale_preference_v97/);
  assert.match(render,/p_locale:next,p_expected_version:platformLocaleVersion/);
  assert.match(source,/get_workspace_locale_preference_v97/);
  assert.match(source,/data-platform-locale="\$\{locale\}"/);
  assert.match(source,/document\.documentElement\.lang=platformLocale/);
});

test('platform language control remains touch friendly on desktop and mobile',async()=>{
  const [source,styles]=await Promise.all([
    read('app/platform-console.js'),read('app/platform-console.css')
  ]);
  assert.match(source,/role="group" aria-label="\$\{escapeHtml\(pt\('Language'\)\)\}"/);
  assert.match(source,/English.*中文.*Bahasa Melayu/s);
  assert.match(styles,/\.platform-locale-switcher button\{[^}]*min-height:44px/s);
  assert.match(styles,/@media\(max-width:760px\)[\s\S]*\.platform-locale-switcher button\{[^}]*min-width:44px/s);
});

test('all static platform interface metadata has real locale copy and no code-like translation',async()=>{
  const [api,source]=await Promise.all([loadConsole(),read('app/platform-console.js')]);
  const explicit=[...source.matchAll(/\bpt\((['"])(.*?)\1/g)].map(match=>match[2]);
  const metadata=[...source.matchAll(/\b(?:title|subtitle|description|caption|label|hint|placeholder|body|message|actionLabel|submitLabel)\s*:\s*(['"])(.*?)\1/g)]
    .map(match=>match[2]);
  const keys=[...new Set([...explicit,...metadata])];
  const invariants=new Set(['WhatsApp','Platform','UEN']);
  for(const locale of ['zh-CN','ms']){
    api.setPlatformLocaleForTest(locale);
    for(const key of keys){
      const translated=api.platformText(key);
      if(!invariants.has(key))assert.notEqual(translated,key,`${locale} is missing: ${key}`);
      assert.doesNotMatch(translated,/```|\$\{|<script|(?:translate|translation|prompt)\s*[:：]/i);
    }
  }
});

test('runtime state, validation and announcement inventory cannot bypass localization',async()=>{
  const [api,source]=await Promise.all([loadConsole(),read('app/platform-console.js')]);
  const explicit=[...new Set([...source.matchAll(/\bpt\((['"])(.*?)\1/g)].map(match=>match[2]))];
  const metadata=[...new Set([...source.matchAll(/\b(?:title|subtitle|description|caption|label|hint|placeholder|body|message|actionLabel|submitLabel)\s*:\s*(['"])(.*?)\1/g)].map(match=>match[2]))];
  const announcements=[...new Set([...source.matchAll(/\.announce\(\s*(['"])(.*?)\1/g)].map(match=>match[2]))];
  assert.equal(explicit.length,855,'update the audited explicit-copy inventory when adding runtime UI');
  assert.equal(metadata.length,682,'update the audited CUI metadata inventory when adding UI metadata');
  assert.equal(announcements.length,40,'update the audited static announcement inventory when adding announcements');
  assert.doesNotMatch(source,/new Error\(\s*(['"])/,'static validation errors must call pt()');
  assert.doesNotMatch(source,/\.textContent\s*=\s*(['"])/,'static runtime element states must call pt()');
  const directErrorDisplays=[...source.matchAll(/error\??\.message/g)]
    .filter(match=>!source.slice(Math.max(0,match.index-90),match.index+120).includes('platformErrorMessage'));
  assert.equal(directErrorDisplays.length,1,'only the internal platform-update detector may inspect raw error.message');
  assert.match(source,/Downloaded \{count\} customers/);
  assert.match(source,/Prospect \{name\} created/);
  assert.match(source,/Billing command status: \{status\}/);
  api.setPlatformLocaleForTest('zh-CN');
  assert.equal(api.platformErrorMessage(new Error('unknown backend detail'),'Export unavailable'),'导出不可用');
});

test('controlled interface statuses localize while live option and row data remain byte-identical',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('zh-CN');
  const captured={};
  const CUI={
    field:options=>(captured.field=options,'field'),
    status:(label,tone)=>(captured.status={label,tone},'status'),
    table:options=>(captured.table=options,'table')
  };
  const localized=api.localizedPlatformCUI(CUI);
  localized.field({label:'Status',control:'select',options:[
    {value:'active',label:'Active'},
    {value:'company-uuid',label:'Home'},
    {value:'consultant-uuid',label:'Business'}
  ]});
  localized.status('Queued','off');
  localized.table({caption:'Platform firm directory',headers:['Firm'],rows:[
    ['Home'],['Business'],['Clear'],['Status'],['Queued']
  ]});
  assert.equal(captured.field.label,'状态');
  assert.equal(captured.field.options[0].label,'有效');
  assert.equal(captured.field.options[1].label,'Home');
  assert.equal(captured.field.options[2].label,'Business');
  assert.equal(captured.status.label,'已排队');
  assert.deepEqual(captured.table.rows,[['Home'],['Business'],['Clear'],['Status'],['Queued']]);
});

test('domain-sensitive glossary distinguishes operational semantics in Chinese and Malay',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('zh-CN');
  assert.deepEqual(
    ['State','Status','Cutover','Lift','Floor','Full'].map(key=>api.platformText(key)),
    ['状态','状态','上线迁移','提升幅度','最低阈值','容量已满']
  );
  api.setPlatformLocaleForTest('ms');
  assert.deepEqual(
    ['State','Status','Cutover','Lift','Floor','Full'].map(key=>api.platformText(key)),
    ['Status','Status','Pengaktifan / migrasi','Peningkatan','Ambang minimum','Kapasiti penuh']
  );
});

test('named runtime templates localize arbitrary values without translating the values',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('zh-CN');
  assert.equal(api.platformText('{count} selected',{count:37}),'已选择 37 个');
  assert.equal(api.platformText('Version {version} · ends in {suffix}',{version:'v<Home>',suffix:'Business'}),'版本 v<Home> · 末四位 Business');
  assert.equal(api.platformText('{amount} remaining',{amount:'SGD 12.34'}),'剩余 SGD 12.34');
  assert.equal(api.platformText('To {status}',{status:'Clear'}),'转为Clear');
  assert.equal(api.platformText('Decision for source row {row}',{row:'Home'}),'源数据第 Home 行的决定');
  assert.equal(api.platformText('{sector} modules',{sector:'Business'}),'Business模块');
  assert.equal(api.platformText('{module} permission',{module:'Clear'}),'Clear权限');
  assert.equal(api.platformText('due {date}',{date:'31 Dec 2026'}),'到期日 31 Dec 2026');
  api.setPlatformLocaleForTest('ms');
  assert.equal(api.platformText('{count} failures',{count:9}),'9 kegagalan');
  assert.equal(api.platformText('Batch {id}',{id:'Home'}),'Kumpulan Home');
  assert.equal(api.platformText('next payment {date}',{date:'31 Dec 2026'}),'bayaran seterusnya 31 Dec 2026');
  assert.equal(api.platformText('{sector} modules',{sector:'Business'}),'Modul Business');
  assert.equal(api.platformText('{module} permission',{module:'Clear'}),'Kebenaran Clear');
  assert.equal(api.platformText('due {date}',{date:'31 Dec 2026'}),'tarikh akhir 31 Dec 2026');
});

test('every literal accessibility and input attribute is localized or an audited technical invariant',async()=>{
  const source=await read('app/platform-console.js');
  const literalAttributes=[...source.matchAll(/\b(aria-label|title|placeholder)="([^"$<]*)"/g)]
    .map(match=>({attribute:match[1],value:match[2]}))
    .filter(item=>item.value);
  assert.deepEqual(literalAttributes,[
    {attribute:'placeholder',value:'price_...'},
    {attribute:'placeholder',value:'price_...'}
  ],'only Stripe price-ID syntax may remain as a literal technical placeholder');
  assert.doesNotMatch(source,/\b(?:aria-label|title)="[A-Za-z]/,'literal English accessibility copy must call pt()');
  assert.match(source,/pt\('Decision for source row \{row\}',\{row:row\.row_number\}\)/);
  assert.match(source,/pt\('\{sector\} modules',\{sector:profile\.label\|\|sectorLabel\(profile\.sector_key\)\}\)/);
  assert.match(source,/pt\('\{module\} permission',\{module:pt\(platformModuleLabels\[key\]\)\}\)/);
  assert.match(source,/aria-label="\$\{escapeHtml\(pt\('Platform access grants'\)\)\}"/);
  assert.match(source,/aria-label="\$\{escapeHtml\(pt\('Scoped onboarding Kanban'\)\)\}"/);
  assert.match(source,/aria-label="\$\{escapeHtml\(pt\('Scoped onboarding list'\)\)\}"/);
  assert.match(source,/aria-label="\$\{escapeHtml\(pt\('Scoped platform summary'\)\)\}"/);
  assert.match(source,/pt\('due \{date\}',\{date:dateTime\(task\.due_at\)\}\)/);
  assert.doesNotMatch(source,/toLocaleDateString\('en-SG'/,'dates must use the selected platform locale');
});

test('every plainLabel use is classified behind localization or structured metadata rendering',async()=>{
  const source=await read('app/platform-console.js');
  const uses=[...source.matchAll(/plainLabel\(/g)];
  assert.equal(uses.length,4,'new plainLabel rendering must be classified as controlled UI, sector data, or structured metadata');
  assert.match(source,/const platformStatus=value=>pt\(plainLabel\(value\)\)/);
  assert.match(source,/function plainLabel\(value\)/);
  assert.match(source,/sectorModuleByKey\.get\(key\)\?\.label\|\|plainLabel\(key\)/);
  assert.match(source,/escapeHtml\(pt\(plainLabel\(key\)\)\)/);
});

test('every controlled enum used by platform forms and rendered rows has Chinese and Malay copy',async()=>{
  const api=await loadConsole();
  const values=`low developing established advanced unverified verified disputed decision_maker champion influencer budget_owner user gatekeeper phone whatsapp email sms video in_person unqualified discovery qualified disqualified unknown not_confirmed range_confirmed approved no_budget medium high exclusive inclusive exempt proposal trial active past_due cancelled unpaid partially_paid paid refunded charged_back quarterly half_yearly annual not_started template_sent received validated completed not_required note call meeting demo document_sent proposal_sent contract_sent payment onboarding_session outbound inbound normal urgent create_checkout create_portal change_cadence resume cancel_at_period_end senior junior initial renewal accrued forfeited draft manual automatic matched mismatch uploaded rejected pending open critical warning info stale clean`
    .split(/\s+/);
  const english=value=>value.replace(/_/g,' ').replace(/\b\w/g,letter=>letter.toUpperCase());
  for(const locale of ['zh-CN','ms']){
    api.setPlatformLocaleForTest(locale);
    const acceptedLoanwords=locale==='ms'?new Set(['video','demo','manual','junior']):new Set();
    for(const value of values){
      if(!acceptedLoanwords.has(value))assert.notEqual(api.platformStatus(value),english(value),`${locale} controlled enum is missing: ${value}`);
    }
  }
});

test('Chinese route renderers localize controlled values while preserving live names and identifiers',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('zh-CN');
  const CUI={
    icon:()=>'',status:(label)=>`[${label}]`,
    emptyState:({title,body})=>`${title}:${body}`,
    card:({title,body})=>`<article><h2>${title}</h2>${body}</article>`
  };
  const importHtml=api.importReviewRowHtml({
    id:'row-1',row_number:7,row_status:'conflict',
    candidates:[{match_basis:'phone',score:98,candidate_prospect_id:'Home-ID'}]
  });
  assert.match(importHtml,/源数据第 7 行/);
  assert.match(importHtml,/审核/);
  assert.match(importHtml,/新增/);
  assert.match(importHtml,/合并来源沿袭/);
  assert.match(importHtml,/Home-ID/);

  const prospectHtml=api.prospectDetailHtml({
    prospect:{current_stage_key:'pending_decision',priority:'high'},
    activities:[{activity_type:'meeting',summary:'Home customer note',occurred_at:'2026-07-29T01:00:00Z'}],
    tasks:[{id:'task-1',status:'open',due_at:'2026-07-30T01:00:00Z'}],
    documents:[{id:'doc-1',original_filename:'Business-plan.pdf',document_type:'proposal',status:'verified',version:2,size_bytes:1200}],
    stage_history:[{to_stage_key:'pending_decision',created_at:'2026-07-29T01:00:00Z'}]
  },CUI);
  assert.match(prospectHtml,/活动与时间线/);
  assert.match(prospectHtml,/会议/);
  assert.match(prospectHtml,/任务与后续行动/);
  assert.match(prospectHtml,/待决定/);
  assert.match(prospectHtml,/已验证/);
  assert.match(prospectHtml,/Home customer note/);
  assert.match(prospectHtml,/Business-plan\.pdf/);

  const billing=api.billingCatalogueRows([{currency:'SGD',cadence:'half_yearly',tax_behavior:'exclusive',active:true}],CUI);
  assert.equal(billing[0][1],'每半年');
  assert.equal(billing[0][5],'不含税');
  const firmBilling=api.billingFirmRows([{business_id:'firm-1',business_name:'Home',status:'active',payment_status:'paid',cadence:'annual',currency:'SGD'}],CUI);
  assert.match(firmBilling[0][0],/>Home</);
  assert.equal(firmBilling[0][3],'每年');
  assert.equal(firmBilling[0][1],'[有效]');

  const commission=api.commissionRosterRows([{consultant_id:'c1',display_name:'Business',tier:'senior',active:false}],CUI);
  assert.match(commission[0][0],/>Business</);
  assert.equal(commission[0][1],'高级');
  assert.equal(commission[0][5],'[已离职]');
  const accrual=api.commissionAccrualRows([{consultant_name:'Clear',commission_phase:'renewal',status:'accrued'}],[],CUI);
  assert.equal(accrual[0][0],'Clear');
  assert.equal(accrual[0][1],'续约');
  assert.equal(accrual[0][2],'[已计提]');

  const automation=api.automationRunRows([{run_mode:'manual',status:'completed',summary:{source:'Home'}}],CUI);
  assert.equal(automation[0][1],'手动');
  assert.equal(automation[0][2],'[已完成]');
  assert.match(automation[0][4],/Home/);
  const chips=api.sectorModuleChipsHtml(['dashboard','reports']);
  assert.match(chips,/title="仪表板">仪表板/);
  assert.match(chips,/title="报告">报告/);
});

test('Malay route renderers localize the same controlled values without translating live data',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('ms');
  const CUI={icon:()=>'',status:(label)=>`[${label}]`,emptyState:({title})=>title,card:({body})=>body};
  const importHtml=api.importReviewRowHtml({id:'r',row_number:3,row_status:'conflict',candidates:[{match_basis:'email',score:90,candidate_prospect_id:'Business-ID'}]});
  assert.match(importHtml,/Baris sumber 3/);
  assert.match(importHtml,/Masukkan baharu/);
  assert.match(importHtml,/Gabungkan salasilah sumber/);
  assert.match(importHtml,/Business-ID/);
  const prospectHtml=api.prospectDetailHtml({
    prospect:{current_stage_key:'pending_decision',priority:'high'},
    activities:[{activity_type:'meeting',summary:'Clear note'}],
    tasks:[{id:'t',status:'open'}],
    documents:[{id:'d',original_filename:'Home.pdf',document_type:'proposal',status:'verified',version:1}]
  },CUI);
  assert.match(prospectHtml,/Aktiviti dan garis masa/);
  assert.match(prospectHtml,/Mesyuarat/);
  assert.match(prospectHtml,/Tugas dan tindakan seterusnya/);
  assert.match(prospectHtml,/Disahkan/);
  assert.match(prospectHtml,/Clear note/);
  assert.match(prospectHtml,/Home\.pdf/);
  assert.equal(api.billingCatalogueRows([{currency:'SGD',cadence:'quarterly',tax_behavior:'inclusive'}],CUI)[0][1],'Suku tahunan');
  assert.equal(api.commissionRosterRows([{display_name:'Home',tier:'senior',active:false}],CUI)[0][1],'Kanan');
  assert.equal(api.automationRunRows([{run_mode:'manual',status:'completed'}],CUI)[0][1],'Manual');
  assert.match(api.sectorModuleChipsHtml(['dashboard']),/title="Papan pemuka">Papan pemuka/);
});

test('ordinary JavaScript strings can never contain inert template interpolation',async()=>{
  const source=await read('app/platform-console.js');
  assert.deepEqual(
    ordinaryStringsContainingInterpolation(source),
    [],
    'use a template literal or precompute localized HTML; ordinary strings render ${...} verbatim'
  );
});

test('all localized empty and omitted branches render translated HTML without template syntax',async()=>{
  const api=await loadConsole();
  const emptyKeys=[
    'The selected scope does not yet have enough customer-group data.',
    'Item-level intelligence is disabled for this firm.',
    'No reliable product/service pair is available in this scope yet.',
    'No firm rows.','No branch rows.','No customer rows in this scope.',
    'No modules added.','No modules removed.',
    'Payments and provider status are currently reconciled.',
    'The latest returned run has no exception items.',
    'Reconciliation history will appear after the first automated run.',
    'No reconciliation runs.','No invoices.','No payment attempts.',
    'No adjustments.','No billing commands.','No accruals.','No payout batches.',
    'This consultant is departed. Editing preserves that status; record a deliberate reactivation as a separate reviewed policy decision.',
    'No active contacts.','No activity recorded.','No tasks.'
  ];
  const notes=[
    ['No recommendation claimed','Peekaa suppresses advice when the exact scope has insufficient or unreliable data.'],
    ['SME acquisition and onboarding omitted','This account does not have Onboarding access. The customer and firm report above remains complete for the selected scope.'],
    ['Subscription billing omitted','This account does not have Billing access. No billing or reconciliation reader was called.']
  ];
  for(const locale of ['zh-CN','ms']){
    api.setPlatformLocaleForTest(locale);
    for(const key of emptyKeys){
      const html=api.localizedEmptyHtml(key);
      assert.ok(!html.includes('${'),`${locale} empty branch leaked interpolation: ${key}`);
      assert.ok(!html.includes(`>${key}<`),`${locale} empty branch stayed English: ${key}`);
    }
    for(const [title,body] of notes){
      const html=api.localizedRouteNoteHtml(title,body);
      assert.ok(!html.includes('${'),`${locale} omitted branch leaked interpolation: ${title}`);
      assert.ok(!html.includes(`>${title}<`),`${locale} omitted title stayed English: ${title}`);
      assert.ok(!html.includes(`>${body}<`),`${locale} omitted body stayed English: ${body}`);
    }
    const more=api.enterpriseLoadMoreCustomersHtml(true);
    assert.ok(more.includes('enterpriseCustomersMore'));
    assert.ok(!more.includes('${'));
    assert.ok(!more.includes('>Load more customers<'));
    assert.equal(api.enterpriseLoadMoreCustomersHtml(false),'');
  }
});

test('prospect lifecycle conditional branches render real localized controls for every state',async()=>{
  const api=await loadConsole();
  const CUI={icon:()=>'<i></i>'};
  for(const locale of ['zh-CN','ms']){
    api.setPlatformLocaleForTest(locale);
    const newLead=api.prospectLifecycleActionsHtml({converted:false,stage:'new_lead',termsAccepted:false},CUI);
    assert.match(newLead,/data-convert/);
    assert.match(newLead,/data-lost/);
    assert.ok(!newLead.includes('${'));
    assert.ok(!newLead.includes('>Convert to client<'));
    assert.ok(!newLead.includes('>Mark lost<'));

    const blockedClient=api.prospectLifecycleActionsHtml({converted:false,stage:'client',termsAccepted:false},CUI);
    assert.match(blockedClient,/data-create-account disabled title="/);
    assert.match(blockedClient,/data-lost/);
    assert.ok(!blockedClient.includes('${'));
    assert.ok(!blockedClient.includes('Accepted or signed commercial terms are required.'));

    const readyClient=api.prospectLifecycleActionsHtml({converted:false,stage:'client',termsAccepted:true},CUI);
    assert.match(readyClient,/data-create-account/);
    assert.doesNotMatch(readyClient,/data-create-account disabled/);
    assert.ok(!readyClient.includes('${'));

    const converted=api.prospectLifecycleActionsHtml({converted:true,stage:'activated',termsAccepted:true},CUI);
    assert.doesNotMatch(converted,/data-create-account|data-convert|data-lost/);
    assert.ok(!converted.includes('${'));
    assert.ok(!converted.includes('Account lifecycle is controlled by onboarding evidence.'));

    const lost=api.prospectLifecycleActionsHtml({converted:false,stage:'lost',termsAccepted:false},CUI);
    assert.match(lost,/data-convert/);
    assert.doesNotMatch(lost,/data-lost/);
    assert.ok(!lost.includes('${'));
  }
});

function rendererCUI(){
  const cell=value=>String(value??'');
  return {
    icon:()=>'<i></i>',
    status:label=>`<span>${cell(label)}</span>`,
    table:({caption='',headers=[],rows=[]})=>`<table aria-label="${cell(caption)}"><thead><tr>${headers.map(header=>`<th>${cell(header)}</th>`).join('')}</tr></thead><tbody>${rows.map(row=>`<tr>${row.map(value=>`<td>${cell(value)}</td>`).join('')}</tr>`).join('')}</tbody></table>`,
    card:({title='',description='',body=''})=>`<section><h3>${cell(title)}</h3><p>${cell(description)}</p>${cell(body)}</section>`,
    emptyState:({title='',body=''})=>`<section><h3>${cell(title)}</h3><p>${cell(body)}</p></section>`
  };
}

test('Chinese and Malay full report, onboarding, and invitation renderers contain no audited English UI',async()=>{
  const api=await loadConsole();
  const report={
    snapshot_at:'2026-07-29T01:00:00Z',
    scope:{from:'2026-07-01',to:'2026-07-29',firm_count:2,branch_count:3,search:'Live SME'},
    summary:{currency_mode:'single',currency:'SGD',net_revenue_cents:12300,cash_collected_cents:12000,returning_rate_pct:45,active_customers:8},
    summary_by_currency:[],insights:[],monthly_trend:[],businesses:[],branches:[],
    methodology:{revenue:'',returning_customer:'',lapsed_customer:''}
  };
  const customers=[
    {business_name:'Live SME',full_name:'Customer One',currency:'SGD',net_revenue_cents:1000,cash_collected_cents:1000,visit_count:2,last_purchase_at:'2026-07-28T01:00:00Z',returning_customer:true},
    {business_name:'Live SME',full_name:'Customer Two',currency:'SGD',net_revenue_cents:500,cash_collected_cents:500,visit_count:1,last_purchase_at:'2026-07-27T01:00:00Z',returning_customer:false}
  ];
  const onboarding={
    checklist:{id:'check-1',status:'in_progress',version:7},
    business:{name:'Live SME'},subscription:{plan_code:'growth',billing_cadence:'annual'},
    items:[{
      item_key:'owner_access',label:'Live evidence item',mandatory:true,verification_mode:'manual',
      status:'blocked',block_reason:'Live block reason',waiver_reason:'Live waiver reason',
      evidence:{source:'Live evidence value'},waivable:true
    }],
    owner_invitations:[],events:[]
  };
  const invitation={raw_token:'live-token',expires_at:'2026-07-30T01:00:00Z'};
  const forbidden=/\b(?:Net revenue|Cash collected|Returning rate|Active customers|Customers|Transactions|Revenue|Pipeline leads|Deals won|Activated|Billing exceptions|Checklist version|Blocked:|Waived:|Evidence:|For privacy, Peekaa|the workspace owner|The invitation expires|Money remains separated|returning-rate denominator)\b/i;
  for(const locale of ['zh-CN','ms']){
    api.setPlatformLocaleForTest(locale);
    const CUI=api.localizedPlatformCUI(rendererCUI());
    const enterprise=api.reportHtml(report,CUI,customers,{total_customers:2});
    const consultant=api.consultativeIntelligenceHtml({
      kpis:{customer_count:2,returning_rate_pct:50,transaction_count:3,net_revenue_cents:1500,currency:'SGD'},
      customer_intelligence:{cohorts:[]},data_quality:{confidence:'high'}
    },{enabled:false,pairs:[]},{recommendations:[]},CUI);
    const crossDomain=api.crossDomainReportHtml({
      report,customers,customerPage:{total_customers:2},
      analytics:{summary:{leads_created:4,won:2,activated:1},scope:{from:'2026-07-01',to:'2026-07-29'},stages:[],source_page:[],loss_reasons:[]},
      billing:[{business_name:'Live SME',status:'past_due',payment_status:'past_due',failed_event_count:1,currency:'SGD'}],
      reconciliation:{runs:[],items:[]},analyticsAvailable:true,billingAvailable:true
    },CUI,{from:'2026-07-01',to:'2026-07-29'});
    const onboardingHtml=api.onboardingPanelHtml(onboarding,null,CUI,true);
    const invitationHtml=api.oneTimeInvitationBodyHtml(invitation,CUI);
    for(const [name,html] of Object.entries({enterprise,consultant,crossDomain,onboardingHtml,invitationHtml})){
      assert.doesNotMatch(html,forbidden,`${locale} ${name} leaked audited English UI`);
      assert.ok(!html.includes('${'),`${locale} ${name} leaked inert interpolation`);
    }
    assert.match(enterprise,locale==='zh-CN'?/数据快照：/:/Petikan data/);
    assert.match(onboardingHtml,locale==='zh-CN'?/检查清单版本 7/:/Versi senarai semak 7/);
    assert.match(invitationHtml,locale==='zh-CN'?/工作区负责人/:/pemilik ruang kerja/);
  }
});

test('KPI and action label map renderers must pass labels through platformText',async()=>{
  const source=await read('app/platform-console.js');
  const labelMaps=[...source.matchAll(/\.map\(\(\[label[^\n]+/g)].map(match=>match[0]);
  assert.ok(labelMaps.length>=9,'expected the audited label-map renderers');
  assert.doesNotMatch(source,/\.map\(\(\[label[^\n]*escapeHtml\(label\)/,'mapped interface labels must never bypass platformText');
  assert.ok(labelMaps.filter(renderer=>renderer.includes('escapeHtml(pt(label))')).length>=8,'expected every KPI/action renderer to localize its label');
});

test('mixed dynamic template inventory is explicitly classified',async()=>{
  const source=await read('app/platform-console.js');
  const inventory=mixedTemplateUiSegments(source);
  const classifications=[
    {kind:'localized-ui',pattern:/^(?:disabled title="§"|name="bank_account_number" inputmode="numeric" placeholder="§")$/},
    {kind:'data-only',pattern:/^(?:§ (?:KB|MB)|Platform import review: §|NPU: §)$/},
    {kind:'technical',pattern:/^(?:nestly:v133:privacy:§:§|platform-§-§|platformNavGroup-§|cursor:§|#\/platform\/(?:firms|reports|onboarding)§|#\/platform\/(?:billing\?business|commissions\?accrual|automation\?incident)=§|#\/platform\/firms\?firm=§|module_mode_§|\[data-module-row="§"\] select|data-platform-scope="§"|\[data-(?:prospect|business-application|accrual-id|incident-id)="§"\]|§-enterprise-(?:report|cross-domain)-§-§\.csv|peekaa-(?:platform-finance|accounting-books)-§-§\.csv|custom__§|§-import-§-errors\.csv|name="§"§+|name="amount" min="0\.01" max="§" step="0\.01"|§_cents|(?:business|prospect):§|permission_§|receipts\/§\/§-§)$/}
  ];
  const classified=inventory.map(entry=>({
    ...entry,kind:classifications.find(rule=>rule.pattern.test(entry.text))?.kind||'unclassified'
  }));
  assert.equal(classified.length,42,'review every interpolated template segment when the inventory changes');
  assert.deepEqual(classified.filter(entry=>entry.kind==='unclassified'),[]);
  assert.equal(classified.filter(entry=>entry.kind==='localized-ui').length,5);
  assert.equal(classified.filter(entry=>entry.kind==='data-only').length,4);
  assert.equal(classified.filter(entry=>entry.kind==='technical').length,33);
});

test('every mixed UI grammar template localizes arbitrary values in Chinese and Malay',async()=>{
  const api=await loadConsole();
  const sentinel='LIVE-SME-Ω';
  const templates=[
    ['{count} firm available.',{count:sentinel}],['{count} firms available.',{count:sentinel}],
    ['{count} firm in this scope. Open a firm for branch and customer detail.',{count:sentinel}],
    ['{count} firms in this scope. Open a firm for branch and customer detail.',{count:sentinel}],
    ['{firm} branches',{firm:sentinel}],['{firm} customers',{firm:sentinel}],
    ['Move {name} to stage',{name:sentinel}],['{count} rows',{count:sentinel}],
    ['{count} ready',{count:sentinel}],['{count} review',{count:sentinel}],['{count} invalid',{count:sentinel}],
    ['{count} valid',{count:sentinel}],['{count} unmapped',{count:sentinel}],['{count} conflicts',{count:sentinel}],
    ['{inserted} inserted · {merged} merged · {skipped} skipped. Source lineage and batch provenance were retained.',{inserted:sentinel,merged:sentinel,skipped:sentinel}],
    ['{count} selected',{count:sentinel}],['{count} subscriptions. Open a firm for invoices, attempts and available commands.',{count:sentinel}],
    ['Branch · {name}',{name:sentinel}],['{percent}% complete',{percent:sentinel}],['{percent}% onboarded',{percent:sentinel}],
    ['{fulfilled}/{total} required',{fulfilled:sentinel,total:sentinel}],['{count} blocked',{count:sentinel}],
    ['Custom source field · {header}',{header:sentinel}],['Column {count}',{count:sentinel}],
    ['Block {label}',{label:sentinel}],['Move to {stage}',{stage:sentinel}],['Confirm {stage}',{stage:sentinel}],
    ['Review {sector} bundle',{sector:sentinel}],['Edit {sector} modules',{sector:sentinel}],
    ['Assign sector to {firm}',{firm:sentinel}],['Override modules for {firm}',{firm:sentinel}]
  ];
  for(const locale of ['zh-CN','ms']){
    api.setPlatformLocaleForTest(locale);
    for(const [key,variables] of templates){
      const rendered=api.platformText(key,variables);
      assert.match(rendered,/LIVE-SME-Ω/,`${locale} lost live data for ${key}`);
      assert.notEqual(rendered,key.replace(/\{[^}]+\}/g,sentinel),`${locale} left English grammar for ${key}`);
    }
  }
});

test('localized roster, enterprise, import, sector and populated billing renderers preserve live values',async()=>{
  const api=await loadConsole();
  const rawCUI=rendererCUI();
  rawCUI.pageHeader=({title='',subtitle=''})=>`<header><h1>${title}</h1><p>${subtitle}</p></header>`;
  rawCUI.field=({label='',placeholder='',options=[]})=>`<label>${label}<input placeholder="${placeholder}"></label>${options.map(option=>`<option>${option.label}</option>`).join('')}`;
  const firm={business_id:'firm-live',name:'Sentinel & Co',legal_name:'Sentinel & Co',industry:'fnb',branches:[{branch_id:'branch-live',name:'Live Branch',active:true}],summary:{}};
  const payload={firms:[firm],snapshot_at:'2026-07-29T01:00:00Z',pagination:{total_firms:1}};
  for(const locale of ['zh-CN','ms']){
    api.setPlatformLocaleForTest(locale);
    const CUI=api.localizedPlatformCUI(rawCUI);
    const roster=api.firmsHtml([firm],CUI);
    const enterprise=api.enterpriseHtml(payload,CUI,{sector:'',businesses:[],branch:'',search:'',from:'2026-07-01',to:'2026-07-29'},[firm],true);
    const detail=api.enterpriseDetailTable(firm,CUI,[{full_name:'Live Customer',phone:'81234567'}],{total_customers:1});
    const reports=api.reportsPageHtml(CUI,{sector:'',businesses:[],branch:'',search:'',from:'2026-07-01',to:'2026-07-29'},[firm]);
    const prospect=api.prospectCardHtml({id:'p1',company_name:'Sentinel & Co',current_stage_key:'new_lead',profile_completeness_pct:42,onboarding_completion_percent:17,onboarding_summary:{mandatoryTotal:3,mandatoryFulfilled:1,blockedItems:[{}]}},CUI);
    const importPreview=api.importMappingSummaryHtml({total:9,ready:5,review:3,invalid:1})+api.importDecisionSummaryHtml({total:9},{valid:5,unmapped:2,conflicts:1,invalid:1})+api.committedImportSummaryText({inserted:5,merged:2,skipped:2});
    const sectors=api.modulePickerHtml([]);
    const billing=api.billingFirmCardHtml([{business_name:'Sentinel & Co',status:'active',payment_status:'paid',cadence:'annual',currency:'SGD'}],CUI);
    const combined=[roster,enterprise,detail,reports,prospect,importPreview,sectors,billing].join('\n');
    const visible=combined.replace(/<[^>]+>/g,' ');
    assert.match(combined,/Sentinel (?:&amp;|&) Co/);
    assert.match(detail,/Live Branch/);
    assert.match(detail,/Live Customer/);
    assert.doesNotMatch(visible,/\b(?:firm available|firm in this scope|branches|customers|Move .* to stage|rows|ready|review|invalid|valid|unmapped|conflicts|inserted|merged|skipped|selected|subscriptions|complete|onboarded|required|blocked)\b/i,`${locale} route renderer leaked mixed English grammar`);
  }
});
